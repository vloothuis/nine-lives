import Foundation
import os
import ResticKit

let backupLog = Logger(subsystem: "com.ninelives.app", category: "backup")

public enum EngineError: LocalizedError, Equatable {
    case engineMissing
    case diskNotConnected(String)
    case diskReadOnly(String)
    case diskFull(String)
    case unsupportedFilesystem(String)
    case repositoryMissing(String)
    case missingPassphrase(String)
    case noSources
    case busy
    case offline(String)
    case serverUnreachable(String)
    case serverRejectedKey(String)
    case hostKeyChanged(String)
    case repositoryChanged(String)

    public var errorDescription: String? {
        switch self {
        case .engineMissing: return "The backup engine (restic) was not found."
        case .diskNotConnected(let n): return "\(n) is not connected."
        case .diskReadOnly(let n): return "\(n) is read-only, so nothing can be saved on it."
        case .diskFull(let n): return "\(n) is almost full. Free up space on the disk or use a larger disk."
        case .unsupportedFilesystem(let f):
            return "The disk is formatted as \(f). Reformat it as APFS in Disk Utility to use it for backups."
        case .repositoryMissing(let n):
            return "The backup folder on \(n) is missing. It may have been moved or deleted."
        case .missingPassphrase(let n):
            return "The passphrase for \(n) is not in your Keychain. Enter your recovery passphrase to continue."
        case .noSources: return "None of the folders to back up exist."
        case .busy: return "Another backup task is running. Try again when it finishes."
        case .offline(let n): return "This Mac is offline, so \(n) cannot be reached."
        case .serverUnreachable(let n): return "Could not reach \(n). Check the address and your network connection."
        case .serverRejectedKey(let n): return "\(n) did not accept the Nine Lives key. Add the key to the server and try again."
        case .hostKeyChanged(let n):
            return "The identity of \(n) changed. This can mean the server was reinstalled, or that someone is intercepting the connection. Backups to it are paused."
        case .repositoryChanged(let n):
            return "The backup folder on \(n) is not the one Nine Lives made, or it was changed. Nothing was backed up. If you replaced it on purpose, remove \(n) in Disks and add it again."
        }
    }
}

public enum ServerProbe: Equatable, Sendable {
    /// The server answered and there is no repository yet at the chosen path.
    case noRepository
    case openable
    case needsPassphrase
    case rejectedKey
    case hostKeyChanged
    case unreachable(String)
    case sftpMissing
    case failed(String, details: String?)
}

public enum ExistingRepository: Equatable, Sendable {
    case none
    case openable
    case needsPassphrase
    case unreadable(String)
}

public struct BackupRunResult: Sendable {
    public var create: CreateResult
    public var kind: BackupRecord.Kind
    /// The snapshot whose folder index applies to the new snapshot.
    public var folderIndexSnapshot: String?
    /// What the next backup needs to decide. Nil when the next one must be full.
    public var incremental: IncrementalState?
    public var storedSize: Int64?
    public var repositoryID: String?
    public var maintenanceWarnings: [String]
    /// The disk after the run. Differs from the input when a switch from borg was completed.
    public var disk: KnownDisk
}

public struct MigrationResult: Sendable {
    public var disk: KnownDisk
    /// Set when the old backups had to be removed before the new ones could be made.
    public var warning: String?
}

public enum RestoreTarget: Sendable {
    /// Put restored items in a new folder inside this directory.
    case folder(URL)
    /// Put items back where they came from, replacing what is there.
    case originalLocation
}

/// Runs the backup, verification and restore workflows for one disk. Holds no mutable state.
public final class BackupEngine: Sendable {
    public let restic: Restic
    /// nl-engine, which makes the snapshots. Without it, `restic backup` is used.
    public let engine: Engine?
    public let secrets: SecretStore
    public let catalogs: CatalogStore

    public static let tag = "ninelives"
    static let minimumFreeSpace: Int64 = 200_000_000
    /// Suffix of the folder that holds the new backups while the old borg backups still exist.
    static let migrationSuffix = "-restic"

    public init(restic: Restic, engine: Engine? = nil, secrets: SecretStore, catalogs: CatalogStore) {
        self.restic = restic
        self.engine = engine
        self.secrets = secrets
        self.catalogs = catalogs
    }

    // MARK: - Repository access

    public func repositoryURL(folder: String, on volume: VolumeInfo) -> URL {
        volume.url.appendingPathComponent(folder, isDirectory: true)
    }

    /// On encrypted disks the repository password is kept in this file next to the backups,
    /// so the backups can be opened with the disk's own password alone.
    func passwordFile(folder: String, on volume: VolumeInfo) -> URL {
        let url = repositoryURL(folder: folder, on: volume)
        return url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent) password.txt")
    }

    private func readPasswordFile(folder: String, on volume: VolumeInfo) -> String? {
        (try? String(contentsOf: passwordFile(folder: folder, on: volume), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func password(for disk: KnownDisk, on volume: VolumeInfo?) -> String? {
        if let p = secrets.passphrase(for: disk.id) { return p }
        guard disk.mode == .authenticated, let volume else { return nil }
        return readPasswordFile(folder: disk.legacyFolder ?? disk.repoFolder, on: volume)
    }

    public func repo(for disk: KnownDisk, on volume: VolumeInfo?) throws -> ResticRepo {
        if let server = disk.remote {
            guard let p = password(for: disk, on: nil) else { throw EngineError.missingPassphrase(disk.name) }
            return ResticRepo(remote: server.location, password: p)
        }
        guard let volume else { throw EngineError.diskNotConnected(disk.name) }
        guard let p = password(for: disk, on: volume) else { throw EngineError.missingPassphrase(disk.name) }
        return ResticRepo(url: repositoryURL(folder: disk.repoFolder, on: volume), password: p)
    }

    // MARK: - Old borg repositories

    /// True when a folder holds a borg repository. Its `config` is a plain INI file, unlike restic's.
    static func isBorgRepository(at url: URL) -> Bool {
        guard let text = try? String(contentsOf: url.appendingPathComponent("config"), encoding: .utf8) else { return false }
        return text.contains("[repository]")
    }

    private func isBorgRepository(_ remote: SFTPLocation) async -> Bool {
        let config = Restic.shellQuote(remote.path + "/config")
        return (try? await restic.runRemote(remote, "grep -qs '^\\[repository\\]' \(config) && echo yes"))?
            .contains("yes") ?? false
    }

    private func removeBorgRepository(at url: URL) throws {
        guard Self.isBorgRepository(at: url) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func removeBorgRepository(_ remote: SFTPLocation) async throws {
        guard await isBorgRepository(remote) else { return }
        try await restic.runRemote(remote, "rm -rf -- \(Restic.shellQuote(remote.path))")
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Size of a folder on the server and the free space next to it, in bytes.
    private func remoteSpace(_ remote: SFTPLocation) async throws -> (used: Int64, free: Int64) {
        let p = Restic.shellQuote(remote.path)
        let out = try await restic.runRemote(remote, "du -sk -- \(p) | cut -f1; df -Pk -- \(p) | tail -1")
        let lines = out.split(separator: "\n")
        guard lines.count >= 2, let used = Int64(lines[0].trimmingCharacters(in: .whitespaces)) else {
            throw ResticError(exitCode: 1, rawMessages: ["Could not read the free space on the server: \(out)"])
        }
        let columns = lines[1].split(separator: " ", omittingEmptySubsequences: true)
        guard columns.count >= 4, let free = Int64(columns[3]) else {
            throw ResticError(exitCode: 1, rawMessages: ["Could not read the free space on the server: \(out)"])
        }
        return (used * 1024, free * 1024)
    }

    // MARK: - Setting up disks

    static var defaultFolder: String { "Nine Lives Backups/\(Machine.folderName)" }

    private func validate(_ volume: VolumeInfo) throws {
        guard volume.isWritable else { throw EngineError.diskReadOnly(volume.name) }
        guard volume.isSupportedFilesystem else { throw EngineError.unsupportedFilesystem(volume.filesystemDisplayName) }
    }

    public func probeExisting(on volume: VolumeInfo) async -> ExistingRepository {
        let folder = Self.defaultFolder
        let url = repositoryURL(folder: folder, on: volume)
        // Old borg backups are replaced when the disk is set up again.
        guard restic.repositoryExists(at: url) else { return .none }
        do {
            guard let pass = secrets.passphrase(for: volume.id) ?? readPasswordFile(folder: folder, on: volume) else {
                return .needsPassphrase
            }
            _ = try await restic.repositoryID(repo: ResticRepo(url: url, password: pass))
            return .openable
        } catch let e as ResticError {
            return e.isWrongPassphrase ? .needsPassphrase : .unreadable(e.localizedDescription)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// Stores a new password for a disk. On encrypted disks it is also written next to the backups.
    private func storeGeneratedPassword(_ pass: String, diskID: String, folder: String, on volume: VolumeInfo) throws {
        try secrets.setPassphrase(pass, for: diskID)
        let file = passwordFile(folder: folder, on: volume)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (pass + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Creates a new repository on the disk. `passphrase` is required when the disk itself is not encrypted.
    public func createDisk(on volume: VolumeInfo, passphrase: String?) async throws -> KnownDisk {
        try validate(volume)
        let mode: EncryptionMode = volume.isEncrypted ? .authenticated : .repokey
        let folder = Self.defaultFolder
        let url = repositoryURL(folder: folder, on: volume)
        let pass: String
        if mode == .repokey {
            guard let passphrase, !passphrase.isEmpty else { throw EngineError.missingPassphrase(volume.name) }
            pass = passphrase
            try secrets.setPassphrase(passphrase, for: volume.id)
        } else {
            pass = PassphraseGenerator.generate()
            try storeGeneratedPassword(pass, diskID: volume.id, folder: folder, on: volume)
        }
        try removeBorgRepository(at: url)
        let id = try await restic.initRepository(ResticRepo(url: url, password: pass))
        writeReadme(near: url, mode: mode)
        var disk = KnownDisk(
            id: volume.id, name: volume.name, mode: mode, diskEncrypted: volume.isEncrypted,
            repoFolder: folder, capacity: volume.totalCapacity)
        disk.repositoryID = id.isEmpty ? nil : id
        return disk
    }

    /// Connects to a repository that already exists on the disk, for example after reinstalling macOS.
    public func adoptDisk(on volume: VolumeInfo, passphrase: String?) async throws -> KnownDisk {
        let folder = Self.defaultFolder
        let url = repositoryURL(folder: folder, on: volume)
        let filePass = readPasswordFile(folder: folder, on: volume)
        let pass = passphrase ?? secrets.passphrase(for: volume.id) ?? filePass ?? ""
        let repo = ResticRepo(url: url, password: pass)
        let id = try await restic.repositoryID(repo: repo)
        let mode: EncryptionMode = volume.isEncrypted && pass == filePass ? .authenticated : .repokey
        try secrets.setPassphrase(pass, for: volume.id)
        var disk = KnownDisk(
            id: volume.id, name: volume.name, mode: mode, diskEncrypted: volume.isEncrypted,
            repoFolder: folder, capacity: volume.totalCapacity)
        disk.repositoryID = id
        disk.storedSize = try? await restic.storedSize(repo: repo)
        disk.lastBackup = try? await restic.listArchives(repo: repo, tag: Self.tag).first?.date
        return disk
    }

    // MARK: - Setting up servers

    /// Looks at the server and the chosen path without changing anything.
    public func probeServer(_ server: RemoteServer, passphrase: String = "") async -> ServerProbe {
        switch await restic.checkSSH(host: server.host, port: server.port, user: server.user) {
        case .ok: break
        case .rejectedKey: return .rejectedKey
        case .hostKeyChanged: return .hostKeyChanged
        case .unreachable(let m): return .unreachable(m)
        }
        // Old borg backups at this path are replaced by a new backup folder.
        if await isBorgRepository(server.location) { return .noRepository }
        do {
            _ = try await restic.repositoryID(repo: ResticRepo(remote: server.location, password: passphrase))
            return .openable
        } catch is CancellationError {
            return .failed("Cancelled", details: nil)
        } catch let e as ResticError {
            if e.isRepositoryMissing { return .noRepository }
            if e.isWrongPassphrase { return .needsPassphrase }
            if e.isSFTPMissing { return .sftpMissing }
            if e.isConnectionProblem { return .unreachable(e.localizedDescription) }
            return .failed(e.summary, details: e.details)
        } catch {
            return .failed(error.localizedDescription, details: nil)
        }
    }

    /// Creates a new encrypted repository on the server. Servers are never trusted with plain data, so a passphrase is required.
    public func createServer(_ server: RemoteServer, passphrase: String) async throws -> KnownDisk {
        guard !passphrase.isEmpty else { throw EngineError.missingPassphrase(server.host) }
        var disk = KnownDisk(server: server)
        try await removeBorgRepository(server.location)
        try await restic.makeRemoteDirectory(server.location)
        let id = try await restic.initRepository(ResticRepo(remote: server.location, password: passphrase))
        try secrets.setPassphrase(passphrase, for: disk.id)
        disk.repositoryID = id.isEmpty ? nil : id
        disk.addedAt = Date()
        return disk
    }

    /// Connects to a repository that already exists on the server.
    public func adoptServer(_ server: RemoteServer, passphrase: String) async throws -> KnownDisk {
        guard !passphrase.isEmpty else { throw EngineError.missingPassphrase(server.host) }
        let repo = ResticRepo(remote: server.location, password: passphrase)
        var disk = KnownDisk(server: server)
        disk.repositoryID = try await restic.repositoryID(repo: repo)
        disk.storedSize = try? await restic.storedSize(repo: repo)
        disk.lastBackup = try? await restic.listArchives(repo: repo, tag: Self.tag).first?.date
        try secrets.setPassphrase(passphrase, for: disk.id)
        return disk
    }

    static func readmeURL(near repoURL: URL) -> URL {
        repoURL.deletingLastPathComponent().appendingPathComponent("HOW TO RESTORE.txt")
    }

    private func writeReadme(near repoURL: URL, mode: EncryptionMode) {
        let readme = Self.readmeURL(near: repoURL)
        let passwordLine = mode == .repokey
            ? "This backup is encrypted. The password is the recovery passphrase that Nine Lives showed you when you set up this disk."
            : "The password is in the file \"\(repoURL.lastPathComponent) password.txt\" next to the backup folder. The disk itself is encrypted."
        let text = """
        Nine Lives backups
        ==================

        This folder contains backups made by Nine Lives. The data is stored
        with restic (https://restic.net), an open format. You can restore without Nine Lives:

          1. Install restic (for example: brew install restic).
          2. \(passwordLine)
          3. List backups:     restic -r "\(repoURL.path)" snapshots
          4. Restore a backup: restic -r "\(repoURL.path)" restore SNAPSHOT-ID --target /some/empty/folder

        Do not edit or delete files inside the backup folders by hand.
        """
        try? text.write(to: readme, atomically: true, encoding: .utf8)
        OpenWith.set(on: readme)
    }

    // MARK: - Switching from borg

    /// Replaces the borg repository of a disk or server with a restic repository and keeps the passphrase.
    ///
    /// When there is room, the new repository is made next to the old one, which is removed after the
    /// first successful backup. Otherwise the old backups are removed first.
    public func migrate(disk: KnownDisk, on volume: VolumeInfo?) async throws -> MigrationResult {
        guard disk.needsMigration else { return MigrationResult(disk: disk) }
        try await ensureReachable(disk)
        var d = disk
        let pass: String
        if disk.mode == .repokey || disk.isRemote {
            guard let p = secrets.passphrase(for: disk.id) else { throw EngineError.missingPassphrase(disk.name) }
            pass = p
        } else {
            guard let volume else { throw EngineError.diskNotConnected(disk.name) }
            pass = readPasswordFile(folder: disk.repoFolder, on: volume) ?? PassphraseGenerator.generate()
            try storeGeneratedPassword(pass, diskID: disk.id, folder: disk.repoFolder, on: volume)
        }
        var warning: String?
        let tooSmall = "There was not enough free space on \(disk.name) to keep the old backups while making the new ones, so the old backups were removed. The new backup starts from scratch."

        if let server = disk.remote {
            let old = server.location
            if await isBorgRepository(old) {
                let space = try await remoteSpace(old)
                if space.free >= space.used + Self.minimumFreeSpace {
                    var next = server
                    next.path = server.path + Self.migrationSuffix
                    try await restic.makeRemoteDirectory(next.location)
                    d.repositoryID = try await initOrOpen(ResticRepo(remote: next.location, password: pass))
                    d.remote = next
                    d.legacyFolder = server.path
                } else {
                    try await removeBorgRepository(old)
                    warning = tooSmall
                }
            }
            if d.legacyFolder == nil {
                try await restic.makeRemoteDirectory(old)
                d.repositoryID = try await initOrOpen(ResticRepo(remote: old, password: pass))
            }
        } else {
            guard let volume else { throw EngineError.diskNotConnected(disk.name) }
            let oldURL = repositoryURL(folder: disk.repoFolder, on: volume)
            if Self.isBorgRepository(at: oldURL) {
                let used = Self.directorySize(oldURL)
                if volume.availableCapacity >= used + Self.minimumFreeSpace {
                    let folder = disk.repoFolder + Self.migrationSuffix
                    d.repositoryID = try await initOrOpen(ResticRepo(url: repositoryURL(folder: folder, on: volume), password: pass))
                    d.repoFolder = folder
                    d.legacyFolder = disk.repoFolder
                } else {
                    try removeBorgRepository(at: oldURL)
                    warning = tooSmall
                }
            }
            if d.legacyFolder == nil {
                d.repositoryID = try await initOrOpen(ResticRepo(url: oldURL, password: pass))
            }
            writeReadme(near: oldURL, mode: disk.mode)
        }
        d.format = .restic
        d.storedSize = nil
        d.lastBackupStats = nil
        d.lastVerification = nil
        return MigrationResult(disk: d, warning: warning)
    }

    /// Creates the repository, or opens it when an earlier, interrupted switch already made it.
    private func initOrOpen(_ repo: ResticRepo) async throws -> String {
        let exists = repo.isRemote
            ? (try? await restic.repositoryID(repo: repo)) != nil
            : restic.repositoryExists(at: repo.url)
        if exists { return try await restic.repositoryID(repo: repo) }
        return try await restic.initRepository(repo)
    }

    /// Removes the old borg backups and moves the new backups to the original folder.
    private func finishMigration(disk: KnownDisk, on volume: VolumeInfo?) async throws -> KnownDisk {
        guard let legacy = disk.legacyFolder else { return disk }
        var d = disk
        if var server = disk.remote {
            var old = server
            old.path = legacy
            try await removeBorgRepository(old.location)
            try await restic.runRemote(server.location,
                "test ! -e \(Restic.shellQuote(legacy)) && mv -- \(Restic.shellQuote(server.path)) \(Restic.shellQuote(legacy))")
            server.path = legacy
            d.remote = server
        } else {
            guard let volume else { return disk }
            let oldURL = repositoryURL(folder: legacy, on: volume)
            try removeBorgRepository(at: oldURL)
            let fm = FileManager.default
            if !fm.fileExists(atPath: oldURL.path) {
                try fm.moveItem(at: repositoryURL(folder: disk.repoFolder, on: volume), to: oldURL)
                d.repoFolder = legacy
            }
        }
        d.legacyFolder = nil
        return d
    }

    // MARK: - Backup

    private func recovering<T>(_ repo: ResticRepo, _ op: () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch let e as ResticError where e.isLockProblem {
            // A previous run was killed. Only one job runs at a time, so the lock is stale.
            try await restic.unlock(repo: repo)
            return try await op()
        }
    }

    /// Fails with a clear error when a server cannot be reached.
    func ensureReachable(_ disk: KnownDisk) async throws {
        guard let s = disk.remote else { return }
        switch await restic.checkSSH(host: s.host, port: s.port, user: s.user) {
        case .ok: return
        case .rejectedKey: throw EngineError.serverRejectedKey(disk.name)
        case .hostKeyChanged: throw EngineError.hostKeyChanged(disk.name)
        case .unreachable: throw EngineError.serverUnreachable(disk.name)
        }
    }

    /// Refuses to use a repository whose ID differs from what was recorded when the disk was added.
    private func checkIdentity(disk: KnownDisk, repo: ResticRepo) async throws -> String {
        let id = try await restic.repositoryID(repo: repo)
        if let known = disk.repositoryID, known != id { throw EngineError.repositoryChanged(disk.name) }
        return id
    }

    public func runBackup(
        disk: KnownDisk,
        on volume: VolumeInfo?,
        settings: BackupSettings,
        starting: @escaping @Sendable (BackupRecord.Kind) -> Void = { _ in },
        progress: @escaping @Sendable (CreateProgress) -> Void
    ) async throws -> BackupRunResult {
        if let volume {
            guard volume.isWritable else { throw EngineError.diskReadOnly(disk.name) }
            guard volume.availableCapacity > Self.minimumFreeSpace else { throw EngineError.diskFull(disk.name) }
        }
        let sources = settings.sources.filter { FileManager.default.fileExists(atPath: $0) }
        guard !sources.isEmpty else { throw EngineError.noSources }
        try await ensureReachable(disk)
        let repo = try repo(for: disk, on: volume)
        if !repo.isRemote {
            guard restic.repositoryExists(at: repo.url) else { throw EngineError.repositoryMissing(disk.name) }
        }

        let id = try await recovering(repo) { try await checkIdentity(disk: disk, repo: repo) }

        let options = CreateOptions(
            sources: sources, excludePatterns: settings.excludePatterns(), includePatterns: settings.includePatterns,
            excludeIfPresent: [".nobackup"] + settings.excludeMarkers,
            excludeGitignored: settings.excludeGitignored, host: Machine.backupHost, tag: Self.tag)
        let made: MadeBackup
        if let engine, !settings.useResticBackup {
            made = try await engineBackup(engine, disk: disk, repo: repo, options: options, starting: starting, progress: progress)
        } else {
            starting(.full)
            let created = try await recovering(repo) {
                try await restic.backup(repo: repo, options: options, progress: progress)
            }
            made = MadeBackup(create: created, kind: .full, folderIndexSnapshot: created.archiveID, incremental: nil)
        }
        let created = made.create

        var warnings: [String] = []
        do {
            try await recovering(repo) {
                try await restic.forget(repo: repo, retention: settings.retention, tag: Self.tag)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            warnings.append("Cleaning up old backups failed: \(error.localizedDescription)")
        }
        var updated = disk
        do {
            updated = try await finishMigration(disk: disk, on: volume)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            warnings.append("Removing the old backups failed: \(error.localizedDescription). Nine Lives tries again after the next backup.")
        }
        // Keeps the readme opening this copy of the app, also after it was moved or updated.
        if !repo.isRemote { OpenWith.set(on: Self.readmeURL(near: repo.url)) }
        let stored = try? await restic.storedSize(repo: try self.repo(for: updated, on: volume))
        return BackupRunResult(
            create: created, kind: made.kind, folderIndexSnapshot: made.folderIndexSnapshot, incremental: made.incremental,
            storedSize: stored, repositoryID: id, maintenanceWarnings: warnings, disk: updated)
    }

    struct MadeBackup {
        var create: CreateResult
        var kind: BackupRecord.Kind
        var folderIndexSnapshot: String?
        var incremental: IncrementalState?
    }

    /// Replaced in tests, which run without Full Disk Access.
    nonisolated(unsafe) static var fullDiskAccess: @Sendable () -> Bool = Permissions.hasFullDiskAccess

    /// Backs up with nl-engine: a splice of the folders FSEvents reports as changed when that is safe,
    /// otherwise a full sweep. A failed splice is followed by a sweep in the same run.
    private func engineBackup(
        _ engine: Engine, disk: KnownDisk, repo: ResticRepo, options: CreateOptions,
        starting: @escaping @Sendable (BackupRecord.Kind) -> Void,
        progress: @escaping @Sendable (CreateProgress) -> Void
    ) async throws -> MadeBackup {
        // Taken before anything is read, so changes made during the backup are seen next time.
        let startEvent = ChangeTracker.currentEventID
        let volumes = ChangeTracker.volumes(of: options.sources)
        let fda = Self.fullDiskAccess()
        let state = disk.incremental
        var facts = ChangeFacts(
            state: state, newestSnapshotID: nil, configHash: ChangeTracker.configHash(options), volumeUUIDs: volumes.uuids,
            currentEventID: startEvent, sourcesInternal: volumes.onInternal, history: nil, fullDiskAccess: fda,
            onMainsPower: !PowerState.current().onBattery, now: Date())
        facts.newestSnapshotID = try await recovering(repo) { try await restic.listArchives(repo: repo, tag: Self.tag) }.first?.id
        if let state {
            if ChangeTracker.precheck(facts) == nil {
                let skipper = PathSkipper(patterns: options.excludePatterns, includes: options.includePatterns)
                facts.history = await ChangeTracker.history(since: state.eventID, sources: options.sources, skip: { skipper.skips($0) })
            }
        }
        var decision = ChangeTracker.decide(facts)
        var notes: [String] = []

        if case .incremental(let changes) = decision, let state {
            starting(.quick)
            do {
                let r = try await recovering(repo) {
                    try await engine.backup(repo: repo, options: options, run: .splice(parent: state.snapshotID, changes: changes), progress: progress)
                }
                backupLog.info("Quick backup of \(changes.count) changed folders: \(r.filesNew) new, \(r.filesChanged) changed files")
                // Items the last sweep could not read stay out of the snapshot. Repeat them, except where
                // this splice looked again.
                let kept = state.sweepErrors.filter { e in !changes.contains { Self.covers($0, e.path) } }
                var create = r.create
                create.warnings = Array((r.errors + kept).map(\.resticStyle).prefix(200))
                var next = state
                next.snapshotID = r.create.archiveID
                next.eventID = startEvent
                next.sweepErrors = Array((kept + r.errors).prefix(2000))
                next.hardLinksChanged = r.hardLinksChanged
                return MadeBackup(create: create, kind: .quick, folderIndexSnapshot: state.sweepSnapshotID, incremental: next)
            } catch let e as ResticError where !(e.isConnectionProblem || e.isLockProblem || e.isWrongPassphrase || e.isOutOfSpace) {
                backupLog.error("Quick backup failed, making a full backup: \(e.summary)")
                notes.append("The quick backup failed, so a full backup was made instead: \(e.summary)")
                decision = .full(reason: "the quick backup failed", force: false)
            }
        }

        guard case .full(let reason, let force) = decision else { preconditionFailure("decided above") }
        backupLog.info("Full backup\(force ? " reading all files" : ""): \(reason, privacy: .public)")
        // The newest snapshot is the parent, also when it was made by restic: files whose size and
        // modification time match are not read again.
        let parent = facts.newestSnapshotID
        starting(.full)
        let r = try await recovering(repo) {
            try await engine.backup(repo: repo, options: options, run: .sweep(parent: parent, force: force), progress: progress)
        }
        if let state, state.snapshotID != state.sweepSnapshotID, r.filesNew + r.filesChanged > 0 {
            backupLog.info("Full backup after quick backups found \(r.filesNew) new and \(r.filesChanged) changed files")
        }
        // Warnings can hold file paths, so they stay private in the system log. They also go into
        // the backup's notes, such as a parent snapshot that could not be used.
        for w in r.engineWarnings { backupLog.notice("Engine: \(w)") }
        notes += r.engineWarnings.prefix(20)
        var create = r.create
        create.warnings = notes + create.warnings
        let now = Date()
        let next = IncrementalState(
            snapshotID: r.create.archiveID, eventID: startEvent, volumeUUIDs: volumes.uuids, configHash: facts.configHash,
            lastSweep: now, lastForcedSweep: force ? now : state?.lastForcedSweep, sweepSnapshotID: r.create.archiveID,
            sweepErrors: Array(r.errors.prefix(2000)), fullDiskAccess: fda, hardLinksChanged: false)
        return MadeBackup(create: create, kind: .full, folderIndexSnapshot: r.create.archiveID, incremental: next)
    }

    /// True when a splice that got `change` reads `path` again: the folder itself, an item directly in
    /// it, or anything below a recursive entry.
    static func covers(_ change: ChangedFolder, _ path: String) -> Bool {
        if change.recursive { return ChangeTracker.isInside(path, change.path) }
        return path == change.path || (path as NSString).deletingLastPathComponent == change.path
    }

    // MARK: - Browsing and restoring

    public func archives(disk: KnownDisk, on volume: VolumeInfo?) async throws -> [ArchiveInfo] {
        try await ensureReachable(disk)
        let repo = try repo(for: disk, on: volume)
        return try await restic.listArchives(repo: repo, tag: Self.tag)
    }

    public func catalog(
        for archive: ArchiveInfo, disk: KnownDisk, on volume: VolumeInfo?,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> Catalog {
        if let cached = catalogs.cached(archiveID: archive.id) { return cached }
        let repo = try repo(for: disk, on: volume)
        return try await catalogs.catalog(for: archive, restic: restic, repo: repo, progress: progress)
    }

    @discardableResult
    public func restore(
        entries: [CatalogEntry], from archive: ArchiveInfo, disk: KnownDisk, on volume: VolumeInfo?, target: RestoreTarget
    ) async throws -> URL {
        let repo = try repo(for: disk, on: volume)
        switch target {
        case .originalLocation:
            _ = try await restic.restore(
                repo: repo, snapshot: archive.id, paths: entries.map(\.path), destination: URL(fileURLWithPath: "/"))
            return URL(fileURLWithPath: entries.first?.originalPath ?? "/")
        case .folder(let parent):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH.mm"
            let base = parent.appendingPathComponent("Restored from backup \(f.string(from: archive.date))", isDirectory: true)
            let fm = FileManager.default
            // restic keeps full paths, so restore into a hidden staging folder and move each item up.
            let staging = base.appendingPathComponent(".nine-lives-restore-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            _ = try await restic.restore(repo: repo, snapshot: archive.id, paths: entries.map(\.path), destination: staging)
            for entry in entries {
                let source = staging.appendingPathComponent(entry.path)
                guard fm.fileExists(atPath: source.path) else { continue }
                var dest = base.appendingPathComponent(entry.name)
                var n = 2
                while fm.fileExists(atPath: dest.path) {
                    dest = base.appendingPathComponent("\(entry.name) \(n)")
                    n += 1
                }
                try fm.moveItem(at: source, to: dest)
            }
            return base
        }
    }

    // MARK: - Verification

    /// Checks the repository and restores a few random files from the newest backup to prove restores work.
    public func verify(
        disk: KnownDisk, on volume: VolumeInfo?, sampleSize: Int = 5,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> VerificationSummary {
        try await ensureReachable(disk)
        let repo = try repo(for: disk, on: volume)
        var problems: [String] = []

        status("Checking the backup folder…")
        let check = try await recovering(repo) { try await restic.check(repo: repo, readDataSubset: "1%") }
        if !check.passed { problems += check.messages.isEmpty ? ["The backup folder has errors."] : check.messages }

        status("Looking up the newest backup…")
        let archives = try await restic.listArchives(repo: repo, tag: Self.tag)
        var restored = 0
        if let latest = archives.first {
            let sample: [SampledFile]
            if let recorded = disk.lastBackupSample, recorded.snapshotID == latest.id, !recorded.files.isEmpty {
                sample = recorded.spread(count: sampleSize)
            } else {
                // No sample from the backup that made this snapshot, so list the snapshot to pick files.
                let catalog = try await catalog(for: latest, disk: disk, on: volume) { n in
                    status("Reading the newest backup… \(n.formatted()) items")
                }
                sample = catalog.randomFiles(count: sampleSize).map { SampledFile(path: $0.path, size: $0.size) }
            }
            if !sample.isEmpty {
                status("Restoring \(sample.count) test files…")
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("NineLives-verify-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: temp) }
                _ = try await restic.restore(repo: repo, snapshot: latest.id, paths: sample.map(\.path), destination: temp)
                for entry in sample {
                    let file = temp.appendingPathComponent(entry.path)
                    let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
                    if size == entry.size {
                        restored += 1
                    } else {
                        problems.append("Could not restore \((entry.path as NSString).lastPathComponent) correctly.")
                    }
                }
            }
        } else {
            problems.append("The disk has no backups yet.")
        }
        return VerificationSummary(date: Date(), repositoryOK: check.passed, filesRestored: restored, problems: problems)
    }
}
