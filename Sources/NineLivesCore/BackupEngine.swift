import Foundation
import BorgKit

public enum EngineError: LocalizedError, Equatable {
    case borgMissing
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
    case borgMissingOnServer(String)

    public var errorDescription: String? {
        switch self {
        case .borgMissing: return "The backup engine (borg) was not found."
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
        case .borgMissingOnServer(let n):
            return "borg is not installed on \(n), or it is not on the server's default path. Install borg there or set its location."
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
    case borgMissing
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
    public var storedSize: Int64?
    public var maintenanceWarnings: [String]
}

public enum RestoreTarget: Sendable {
    /// Put restored items in a new folder inside this directory.
    case folder(URL)
    /// Put items back where they came from, replacing what is there.
    case originalLocation
}

/// Runs the backup, verification and restore workflows for one disk. Holds no mutable state.
public final class BackupEngine: Sendable {
    public let borg: Borg
    public let secrets: SecretStore
    public let catalogs: CatalogStore

    public static let archivePrefix = "ninelives-"
    static let minimumFreeSpace: Int64 = 200_000_000

    public init(borg: Borg, secrets: SecretStore, catalogs: CatalogStore) {
        self.borg = borg
        self.secrets = secrets
        self.catalogs = catalogs
    }

    // MARK: - Repository access

    public func repositoryURL(folder: String, on volume: VolumeInfo) -> URL {
        volume.url.appendingPathComponent(folder, isDirectory: true)
    }

    public func repo(for disk: KnownDisk, on volume: VolumeInfo?) throws -> BorgRepo {
        if let server = disk.remote {
            guard let p = secrets.passphrase(for: disk.id) else { throw EngineError.missingPassphrase(disk.name) }
            return BorgRepo(remote: server.location, remotePath: server.borgPath, passphrase: p)
        }
        guard let volume else { throw EngineError.diskNotConnected(disk.name) }
        let url = repositoryURL(folder: disk.repoFolder, on: volume)
        switch disk.mode {
        case .authenticated:
            return BorgRepo(url: url, passphrase: "")
        case .repokey:
            guard let p = secrets.passphrase(for: disk.id) else { throw EngineError.missingPassphrase(disk.name) }
            return BorgRepo(url: url, passphrase: p)
        }
    }

    // MARK: - Setting up disks

    static var defaultFolder: String { "Nine Lives Backups/\(Machine.folderName)" }

    private func validate(_ volume: VolumeInfo) throws {
        guard volume.isWritable else { throw EngineError.diskReadOnly(volume.name) }
        guard volume.isSupportedFilesystem else { throw EngineError.unsupportedFilesystem(volume.filesystemDisplayName) }
    }

    public func probeExisting(on volume: VolumeInfo) async -> ExistingRepository {
        let url = repositoryURL(folder: Self.defaultFolder, on: volume)
        guard borg.repositoryExists(at: url) else { return .none }
        do {
            let pass = secrets.passphrase(for: volume.id) ?? ""
            _ = try await borg.info(repo: BorgRepo(url: url, passphrase: pass))
            return .openable
        } catch let e as BorgError {
            return e.isWrongPassphrase ? .needsPassphrase : .unreadable(e.localizedDescription)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// Creates a new repository on the disk. `passphrase` is required when the disk itself is not encrypted.
    public func createDisk(on volume: VolumeInfo, passphrase: String?) async throws -> KnownDisk {
        try validate(volume)
        let mode: EncryptionMode = volume.isEncrypted ? .authenticated : .repokey
        let folder = Self.defaultFolder
        let url = repositoryURL(folder: folder, on: volume)
        var pass = ""
        if mode == .repokey {
            guard let passphrase, !passphrase.isEmpty else { throw EngineError.missingPassphrase(volume.name) }
            pass = passphrase
            try secrets.setPassphrase(passphrase, for: volume.id)
        }
        try await borg.initRepository(BorgRepo(url: url, passphrase: pass), mode: mode)
        writeReadme(near: url, mode: mode)
        return KnownDisk(
            id: volume.id, name: volume.name, mode: mode, diskEncrypted: volume.isEncrypted,
            repoFolder: folder, capacity: volume.totalCapacity)
    }

    /// Connects to a repository that already exists on the disk, for example after reinstalling macOS.
    public func adoptDisk(on volume: VolumeInfo, passphrase: String?) async throws -> KnownDisk {
        let folder = Self.defaultFolder
        let url = repositoryURL(folder: folder, on: volume)
        let pass = passphrase ?? secrets.passphrase(for: volume.id) ?? ""
        let info = try await borg.info(repo: BorgRepo(url: url, passphrase: pass))
        let mode = EncryptionMode(rawValue: info.encryption) ?? .repokey
        if mode == .repokey { try secrets.setPassphrase(pass, for: volume.id) }
        var disk = KnownDisk(
            id: volume.id, name: volume.name, mode: mode, diskEncrypted: volume.isEncrypted,
            repoFolder: folder, capacity: volume.totalCapacity)
        disk.storedSize = info.storedSize
        if let latest = try? await borg.listArchives(repo: BorgRepo(url: url, passphrase: pass), glob: Self.archivePrefix + "*").first {
            disk.lastBackup = latest.date
        }
        return disk
    }

    // MARK: - Setting up servers

    /// Looks at the server and the chosen path without changing anything.
    public func probeServer(_ server: RemoteServer, passphrase: String = "") async -> ServerProbe {
        switch await borg.checkSSH(host: server.host, port: server.port, user: server.user) {
        case .ok: break
        case .rejectedKey: return .rejectedKey
        case .hostKeyChanged: return .hostKeyChanged
        case .unreachable(let m): return .unreachable(m)
        }
        let repo = BorgRepo(remote: server.location, remotePath: server.borgPath, passphrase: passphrase)
        do {
            _ = try await borg.info(repo: repo)
            return .openable
        } catch is CancellationError {
            return .failed("Cancelled", details: nil)
        } catch let e as BorgError {
            if e.isRepositoryMissing { return .noRepository }
            if e.isWrongPassphrase { return .needsPassphrase }
            // ssh itself worked, so a closed connection means borg is missing or broken on the server.
            if e.isBorgMissingOnServer || (e.msgid ?? "").contains("ConnectionClosed") { return .borgMissing }
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
        try await borg.makeRemoteDirectory(host: server.host, port: server.port, user: server.user, path: server.path)
        try await borg.initRepository(
            BorgRepo(remote: server.location, remotePath: server.borgPath, passphrase: passphrase), mode: .repokey)
        try secrets.setPassphrase(passphrase, for: disk.id)
        disk.addedAt = Date()
        return disk
    }

    /// Connects to a repository that already exists on the server.
    public func adoptServer(_ server: RemoteServer, passphrase: String) async throws -> KnownDisk {
        let repo = BorgRepo(remote: server.location, remotePath: server.borgPath, passphrase: passphrase)
        let info = try await borg.info(repo: repo)
        var disk = KnownDisk(server: server)
        disk.storedSize = info.storedSize
        if let latest = try? await borg.listArchives(repo: repo, glob: Self.archivePrefix + "*").first {
            disk.lastBackup = latest.date
        }
        try secrets.setPassphrase(passphrase, for: disk.id)
        return disk
    }

    private func writeReadme(near repoURL: URL, mode: EncryptionMode) {
        let readme = repoURL.deletingLastPathComponent().appendingPathComponent("HOW TO RESTORE.txt")
        let passphraseLine = mode == .repokey
            ? "This backup is encrypted. You need the recovery passphrase that Nine Lives showed you when you set up this disk."
            : "The disk itself is encrypted. Unlock the disk with its password, no extra passphrase is needed."
        let text = """
        Nine Lives backups
        ==================

        This folder contains backups made by Nine Lives. The data is stored
        with BorgBackup (https://www.borgbackup.org), an open format. You can restore without Nine Lives:

          1. Install borg (for example: brew install borgbackup).
          2. \(passphraseLine)
          3. List backups:    borg list "\(repoURL.path)"
          4. Restore a backup: cd /some/empty/folder && borg extract "\(repoURL.path)::ARCHIVE-NAME"

        Do not edit or delete files inside the backup folders by hand.
        """
        try? text.write(to: readme, atomically: true, encoding: .utf8)
    }

    // MARK: - Backup

    static func archiveName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return archivePrefix + f.string(from: date)
    }

    private func recovering<T>(_ repo: BorgRepo, _ op: () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch let e as BorgError where e.isLockProblem {
            // A previous run was killed. Only one job runs at a time, so the lock is stale.
            try await borg.breakLock(repo: repo)
            return try await op()
        }
    }

    /// Fails with a clear error when a server cannot be reached.
    func ensureReachable(_ disk: KnownDisk) async throws {
        guard let s = disk.remote else { return }
        switch await borg.checkSSH(host: s.host, port: s.port, user: s.user) {
        case .ok: return
        case .rejectedKey: throw EngineError.serverRejectedKey(disk.name)
        case .hostKeyChanged: throw EngineError.hostKeyChanged(disk.name)
        case .unreachable: throw EngineError.serverUnreachable(disk.name)
        }
    }

    public func runBackup(
        disk: KnownDisk,
        on volume: VolumeInfo?,
        settings: BackupSettings,
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
            guard borg.repositoryExists(at: repo.url) else { throw EngineError.repositoryMissing(disk.name) }
        }

        let options = CreateOptions(sources: sources, excludePatterns: settings.excludePatterns())
        let name = Self.archiveName()
        let created = try await recovering(repo) {
            try await borg.create(repo: repo, archive: name, options: options, progress: progress)
        }

        var warnings: [String] = []
        do {
            try await borg.prune(repo: repo, retention: settings.retention, glob: Self.archivePrefix + "*")
            try await borg.compact(repo: repo)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            warnings.append("Cleaning up old backups failed: \(error.localizedDescription)")
        }
        let stored = try? await borg.info(repo: repo).storedSize
        return BackupRunResult(create: created, storedSize: stored, maintenanceWarnings: warnings)
    }

    // MARK: - Browsing and restoring

    public func archives(disk: KnownDisk, on volume: VolumeInfo?) async throws -> [ArchiveInfo] {
        try await ensureReachable(disk)
        let repo = try repo(for: disk, on: volume)
        return try await borg.listArchives(repo: repo, glob: Self.archivePrefix + "*")
    }

    public func catalog(
        for archive: ArchiveInfo, disk: KnownDisk, on volume: VolumeInfo?,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> Catalog {
        if let cached = catalogs.cached(archiveID: archive.id) { return cached }
        let repo = try repo(for: disk, on: volume)
        return try await catalogs.catalog(for: archive, borg: borg, repo: repo, progress: progress)
    }

    @discardableResult
    public func restore(
        entries: [CatalogEntry], from archive: ArchiveInfo, disk: KnownDisk, on volume: VolumeInfo?, target: RestoreTarget
    ) async throws -> URL {
        let repo = try repo(for: disk, on: volume)
        switch target {
        case .originalLocation:
            _ = try await borg.extract(
                repo: repo, archive: archive.name, paths: entries.map(\.path), destination: URL(fileURLWithPath: "/"))
            return URL(fileURLWithPath: entries.first?.originalPath ?? "/")
        case .folder(let parent):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH.mm"
            let base = parent.appendingPathComponent("Restored from backup \(f.string(from: archive.date))", isDirectory: true)
            for entry in entries {
                let depth = entry.path.split(separator: "/").count
                _ = try await borg.extract(
                    repo: repo, archive: archive.name, paths: [entry.path], destination: base,
                    stripComponents: max(depth - 1, 0))
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
        let check = try await recovering(repo) { try await borg.check(repo: repo, maxDuration: 600) }
        if !check.passed { problems += check.messages.isEmpty ? ["The backup folder has errors."] : check.messages }

        status("Reading the newest backup…")
        let archives = try await borg.listArchives(repo: repo, glob: Self.archivePrefix + "*")
        var restored = 0
        if let latest = archives.first {
            let catalog = try await catalog(for: latest, disk: disk, on: volume) { n in
                status("Reading the newest backup… \(n.formatted()) items")
            }
            let sample = catalog.randomFiles(count: sampleSize)
            if !sample.isEmpty {
                status("Restoring \(sample.count) test files…")
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("NineLives-verify-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: temp) }
                _ = try await borg.extract(repo: repo, archive: latest.name, paths: sample.map(\.path), destination: temp)
                for entry in sample {
                    let file = temp.appendingPathComponent(entry.path)
                    let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
                    if size == entry.size { restored += 1 } else { problems.append("Could not restore \(entry.name) correctly.") }
                }
            }
        } else {
            problems.append("The disk has no backups yet.")
        }
        return VerificationSummary(date: Date(), repositoryOK: check.passed, filesRestored: restored, problems: problems)
    }
}
