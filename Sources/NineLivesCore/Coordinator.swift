import Foundation
import AppKit
import Network
import ResticKit

public struct ProgressInfo: Equatable, Sendable {
    public var files: Int64 = 0
    public var bytes: Int64 = 0
    /// Bytes added to the repository so far (after deduplication and compression).
    public var sentBytes: Int64 = 0
    public var fraction: Double?
    public var currentPath = ""
    public var started = Date()
}

public enum Activity: Equatable, Sendable {
    case idle
    case backingUp(diskID: String, ProgressInfo)
    case verifying(diskID: String, String)
    case working(String)

    public var isIdle: Bool { self == .idle }
}

public enum OverallStatus: Equatable, Sendable {
    case needsSetup
    case running(String)
    case ok(Date)
    case warning(String)
    case error(String)
}

/// Owns app state and decides when to back up. All restic work runs in engine tasks.
@MainActor
@Observable
public final class BackupCoordinator {
    public private(set) var state: AppState
    public private(set) var activity: Activity = .idle
    public let monitor = DiskMonitor()
    public private(set) var engine: BackupEngine?
    /// True when the Mac has a usable network connection.
    public private(set) var networkAvailable = true
    /// True on a hotspot or in Low Data Mode, where scheduled backups to servers wait.
    public private(set) var networkMetered = false

    /// Large items found after a backup that wait for the user to choose.
    public private(set) var optionalFindings: [OptionalFinding] = []

    @ObservationIgnored private var announcedFindings: Set<String> = []
    @ObservationIgnored private let store: StateStore
    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var currentTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var probing = false
    public var sshKeys: SSHKeyStore { SSHKeyStore(directory: store.sshDirectory) }

    public init(store: StateStore = StateStore(), secrets: SecretStore = KeychainSecretStore()) {
        self.store = store
        self.secrets = secrets
        self.state = store.load()
        rebuildEngine()
    }

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        monitor.onMount = { [weak self] volume in self?.handleMount(volume) }
        monitor.start()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.networkChanged(path) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "org.ninelives.network"))
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                self?.tick()
            }
        }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.monitor.refresh(announce: false)
            self?.tick()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.tick()
            }
        }
    }

    private func networkChanged(_ path: NWPath) {
        let wasOnline = networkAvailable
        networkAvailable = path.status == .satisfied
        networkMetered = path.isExpensive || path.isConstrained
        // Back up soon after the connection returns, for example when coming home.
        if networkAvailable, !wasOnline {
            Task {
                try? await Task.sleep(for: .seconds(15))
                self.tick()
            }
        }
    }

    public func requestNotificationPermission() async -> Bool { await notifier.requestAuthorization() }

    private func rebuildEngine() {
        try? FileManager.default.removeItem(at: store.legacyBorgDirectory)
        guard let bin = ResticBinary.locate(override: state.settings.enginePathOverride) else {
            engine = nil
            return
        }
        engine = BackupEngine(
            restic: Restic(binary: bin, cacheDirectory: store.cacheDirectory, ssh: sshKeys.options),
            secrets: secrets,
            catalogs: CatalogStore(directory: store.catalogDirectory))
    }

    public var engineAvailable: Bool { engine != nil }

    // MARK: - State changes

    private func save() { store.save(state) }

    public func updateSettings(_ change: (inout BackupSettings) -> Void) {
        let oldPath = state.settings.enginePathOverride
        change(&state.settings)
        if state.settings.enginePathOverride != oldPath { rebuildEngine() }
        save()
    }

    public func completeOnboarding() {
        state.onboardingComplete = true
        save()
    }

    private func updateDisk(_ id: String, _ change: (inout KnownDisk) -> Void) {
        guard let i = state.disks.firstIndex(where: { $0.id == id }) else { return }
        change(&state.disks[i])
        save()
    }

    private func addRecord(_ r: BackupRecord) {
        state.history.insert(r, at: 0)
        if state.history.count > 300 { state.history.removeLast(state.history.count - 300) }
        save()
    }

    public func disk(_ id: String) -> KnownDisk? { state.disks.first { $0.id == id } }

    public func connectedVolume(for disk: KnownDisk) -> VolumeInfo? { monitor.volume(withID: disk.id) }

    /// A disk is connected when it is mounted. A server counts as connected when the Mac is online.
    public func isConnected(_ disk: KnownDisk) -> Bool {
        disk.isRemote ? networkAvailable : connectedVolume(for: disk) != nil
    }

    /// What the engine needs to reach this disk: its volume, nothing for a server, or an error.
    private func access(to disk: KnownDisk) throws -> VolumeInfo? {
        if disk.isRemote {
            guard networkAvailable else { throw EngineError.offline(disk.name) }
            return nil
        }
        guard let v = connectedVolume(for: disk) else { throw EngineError.diskNotConnected(disk.name) }
        return v
    }

    /// Scheduled work to a server waits on hotspots and in Low Data Mode.
    private func mayRunScheduled(_ disk: KnownDisk) -> Bool {
        !(disk.isRemote && networkMetered)
    }

    // MARK: - Disk management

    public func probeExisting(on volume: VolumeInfo) async -> ExistingRepository {
        guard let engine else { return .none }
        return await engine.probeExisting(on: volume)
    }

    public func addNewDisk(_ volume: VolumeInfo, passphrase: String?) async throws {
        guard let engine else { throw EngineError.engineMissing }
        let disk = try await engine.createDisk(on: volume, passphrase: passphrase)
        state.disks.removeAll { $0.id == disk.id }
        state.disks.append(disk)
        save()
    }

    public func adoptDisk(_ volume: VolumeInfo, passphrase: String?) async throws {
        guard let engine else { throw EngineError.engineMissing }
        let disk = try await engine.adoptDisk(on: volume, passphrase: passphrase)
        state.disks.removeAll { $0.id == disk.id }
        state.disks.append(disk)
        save()
    }

    // MARK: - Servers

    /// Creates the SSH key if needed and returns the public key to install on the server.
    public func sshPublicKey() throws -> String { try sshKeys.ensureKey() }

    public func probeServer(_ server: RemoteServer, passphrase: String = "") async -> ServerProbe {
        guard let engine else { return .failed(EngineError.engineMissing.localizedDescription, details: nil) }
        do { try sshKeys.ensureKey() } catch { return .failed(error.localizedDescription, details: nil) }
        return await engine.probeServer(server, passphrase: passphrase)
    }

    public func addServer(_ server: RemoteServer, passphrase: String, existing: Bool) async throws {
        guard let engine else { throw EngineError.engineMissing }
        try sshKeys.ensureKey()
        let disk = existing
            ? try await engine.adoptServer(server, passphrase: passphrase)
            : try await engine.createServer(server, passphrase: passphrase)
        state.disks.append(disk)
        save()
    }

    /// Stops using a disk. The backups on it stay untouched.
    public func forgetDisk(_ id: String, removePassphrase: Bool = false) {
        state.disks.removeAll { $0.id == id }
        if removePassphrase { secrets.removePassphrase(for: id) }
        save()
    }

    public func recoveryPassphrase(for disk: KnownDisk) -> String? {
        disk.mode == .repokey ? secrets.passphrase(for: disk.id) : nil
    }

    public func eject(_ disk: KnownDisk) throws {
        guard let v = connectedVolume(for: disk) else { return }
        try NSWorkspace.shared.unmountAndEjectDevice(at: v.url)
    }

    // MARK: - Scheduling

    private func handleMount(_ volume: VolumeInfo) {
        guard let disk = disk(volume.id) else { return }
        startBackup(diskID: disk.id, trigger: .plugIn)
    }

    /// Server backups run only when the server answers, so a laptop away from the server's network stays quiet.
    private func probeThenRun(_ disk: KnownDisk, _ action: @escaping @MainActor (BackupCoordinator) -> Void) {
        guard let remote = disk.remote, !probing else { return }
        probing = true
        Task {
            let ok = await ServerReachability.isReachable(host: remote.host, port: remote.port)
            probing = false
            if ok, activity.isIdle { action(self) }
        }
    }

    public func tick() {
        let now = Date()
        remindIfStale(now: now)
        guard activity.isIdle, engine != nil else { return }
        let power = PowerState.current()
        guard Policy.canRunOnPower(onBattery: power.onBattery, percent: power.percent,
                                   pauseOnLowBattery: state.settings.pauseOnLowBattery) else { return }
        for disk in state.disks where isConnected(disk) && mayRunScheduled(disk) && state.settings.intervalMinutes > 0 {
            if Policy.isBackupDue(lastBackup: disk.lastBackup, now: now, intervalMinutes: state.settings.intervalMinutes,
                                  lastFailure: disk.lastFailure) {
                if disk.isRemote {
                    probeThenRun(disk) { $0.startBackup(diskID: disk.id, trigger: .scheduled) }
                    continue
                }
                startBackup(diskID: disk.id, trigger: .scheduled)
                return
            }
        }
        for disk in state.disks where isConnected(disk) && mayRunScheduled(disk) && disk.lastFailure == nil {
            if Policy.isVerificationDue(last: disk.lastVerification, now: now, everyDays: state.settings.verifyEveryDays),
               disk.lastBackup != nil {
                if disk.isRemote {
                    probeThenRun(disk) { $0.startVerification(diskID: disk.id) }
                    continue
                }
                startVerification(diskID: disk.id)
                return
            }
        }
    }

    private func remindIfStale(now: Date) {
        guard state.onboardingComplete else { return }
        let s = Policy.staleness(disks: state.disks, now: now, remindAfterDays: state.settings.remindAfterDays)
        guard s != .fresh, Policy.shouldReminder(now: now, lastReminder: state.lastStaleReminder) else { return }
        let suggestion = state.disks.min { ($0.lastBackup ?? .distantPast) < ($1.lastBackup ?? .distantPast) }?.name ?? "your backup disk"
        switch s {
        case .stale(let days):
            notifier.post(title: "Your Mac needs a backup",
                          body: "The last backup was \(days) days ago. Plug in \(suggestion) to back up.", id: "stale", sound: true)
        case .neverBackedUp:
            notifier.post(title: "No backup yet", body: "Plug in \(suggestion) to make your first backup.", id: "stale")
        case .fresh: break
        }
        state.lastStaleReminder = now
        save()
    }

    // MARK: - Backup

    public func startBackup(diskID: String, trigger: BackupTrigger) {
        guard activity.isIdle, let engine, let disk = disk(diskID) else { return }
        let volume: VolumeInfo?
        do { volume = try access(to: disk) } catch { return }
        var info = ProgressInfo()
        info.started = Date()
        activity = .backingUp(diskID: diskID, info)
        currentTask = Task { await self.performBackup(engine: engine, disk: disk, volume: volume, trigger: trigger) }
    }

    public func cancelCurrent() { currentTask?.cancel() }

    private func beginKeepAwake(_ reason: String) {
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: reason)
    }

    private func endKeepAwake() {
        if let a = sleepActivity { ProcessInfo.processInfo.endActivity(a) }
        sleepActivity = nil
    }

    private func updateProgress(_ p: CreateProgress, previousFiles: Int64) {
        guard case .backingUp(let id, var info) = activity else { return }
        info.files = p.fileCount
        info.bytes = p.originalSize
        info.sentBytes = p.deduplicatedSize
        info.currentPath = p.currentPath
        if let f = p.fraction {
            info.fraction = min(f, 0.99)
        } else if previousFiles > 0 {
            info.fraction = min(Double(p.fileCount) / Double(previousFiles), 0.99)
        }
        activity = .backingUp(diskID: id, info)
    }

    private func performBackup(engine: BackupEngine, disk: KnownDisk, volume: VolumeInfo?, trigger: BackupTrigger) async {
        let start = Date()
        let previousFiles = disk.lastBackupStats?.fileCount ?? 0
        beginKeepAwake("Backing up to \(disk.name)")
        defer { endKeepAwake() }
        var record = BackupRecord(diskID: disk.id, diskName: disk.name, start: start, end: start, outcome: .success, trigger: trigger)
        var ejected = false
        var ejectProblem = false

        do {
            var disk = disk
            var migrationWarning: String?
            if disk.needsMigration {
                let m = try await engine.migrate(disk: disk, on: volume)
                disk = m.disk
                migrationWarning = m.warning
                updateDisk(disk.id) { $0 = disk }
                if let w = m.warning {
                    notifier.post(title: "Old backups removed", body: w, id: "migrate-\(disk.id)", sound: true)
                }
            }
            let result = try await engine.runBackup(disk: disk, on: volume, settings: state.settings) { [weak self] p in
                Task { @MainActor in self?.updateProgress(p, previousFiles: previousFiles) }
            }
            let end = Date()
            record.end = end
            record.archiveName = result.create.archiveName
            record.stats = result.create.stats
            record.messages = (migrationWarning.map { [$0] } ?? []) + result.create.warnings + result.maintenanceWarnings
            record.outcome = record.messages.isEmpty ? .success : .warning
            updateDisk(disk.id) {
                $0.repoFolder = result.disk.repoFolder
                $0.remote = result.disk.remote
                $0.legacyFolder = result.disk.legacyFolder
                $0.lastBackup = end
                $0.lastBackupStats = result.create.stats
                $0.lastBackupDuration = end.timeIntervalSince(start)
                $0.storedSize = result.storedSize ?? $0.storedSize
                $0.repositoryID = $0.repositoryID ?? result.repositoryID
                $0.lastFailure = nil
                if let volume {
                    $0.capacity = volume.totalCapacity
                    $0.name = volume.name
                }
            }
            if trigger == .plugIn, state.settings.ejectAfterPlugIn, !disk.isRemote {
                do { try eject(disk); ejected = true } catch { ejectProblem = true }
            }
        } catch {
            record.end = Date()
            if Task.isCancelled || error is CancellationError {
                record.outcome = .cancelled
            } else {
                record.outcome = .failed
                record.messages = [Self.friendly(error)]
                record.details = Self.details(error)
                if trigger == .scheduled { updateDisk(disk.id) { $0.lastFailure = Date() } }
            }
        }

        addRecord(record)
        activity = .idle
        notifyBackupFinished(record, disk: disk, ejected: ejected, ejectProblem: ejectProblem)
        currentTask = nil
        if record.outcome == .success || record.outcome == .warning { scanForOptionalItems() }
        if record.outcome == .success || record.outcome == .warning, !ejected {
            // Verification runs right after a backup when it is due and the disk is still connected.
            if let d = self.disk(disk.id),
               Policy.isVerificationDue(last: d.lastVerification, now: Date(), everyDays: state.settings.verifyEveryDays) {
                startVerification(diskID: d.id)
            }
        }
    }

    // MARK: - Large optional items

    private func scanForOptionalItems() {
        let settings = state.settings
        Task { [weak self] in
            let findings = await Task.detached(priority: .utility) {
                OptionalScanner.scan(rules: settings.rules, answered: settings.answeredRuleIDs,
                                     answeredPaths: Set(settings.pathChoices.keys), sources: settings.sources)
            }.value
            guard let self else { return }
            self.optionalFindings = findings
            let fresh = findings.filter { !self.announcedFindings.contains($0.id) }
            guard !fresh.isEmpty else { return }
            self.announcedFindings.formUnion(fresh.map(\.id))
            let names = fresh.prefix(2).map { "\($0.title) (\(Self.sizeText($0.size)))" }.joined(separator: ", ")
            self.notifier.post(title: "Large items are not backed up yet",
                               body: "\(names)\(fresh.count > 2 ? " and more" : ""). Open Nine Lives to choose.",
                               id: "optional-items")
        }
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Answers for every item of this kind, now and later. Backing up stops skipping the kind.
    public func answerOptional(_ finding: OptionalFinding, backUp: Bool) {
        updateSettings {
            if let i = $0.rules.firstIndex(where: { $0.id == finding.id }) { $0.rules[i].enabled = !backUp }
            if !$0.answeredRuleIDs.contains(finding.id) { $0.answeredRuleIDs.append(finding.id) }
            for path in finding.paths { $0.pathChoices[path] = nil }
        }
        optionalFindings.removeAll { $0.id == finding.id }
    }

    /// Answers for one item. The kind stays unanswered, so new items of it are asked about later.
    public func answerOptional(_ item: OptionalItem, in finding: OptionalFinding, backUp: Bool) {
        updateSettings { $0.pathChoices[item.path] = backUp }
        guard let i = optionalFindings.firstIndex(where: { $0.id == finding.id }) else { return }
        optionalFindings[i].items.removeAll { $0.path == item.path }
        if optionalFindings[i].items.isEmpty { optionalFindings.remove(at: i) }
    }

    /// Adds a rule that skips this folder from the next backup on.
    public func skipFolder(_ path: String) {
        guard BackupNotes.canSkip(path), !isSkipped(path) else { return }
        updateSettings {
            $0.rules.append(ExcludeRule(id: UUID().uuidString, title: (path as NSString).abbreviatingWithTildeInPath,
                                        detail: "Added by you from backup notes", kind: .absolute,
                                        value: BackupNotes.escapedPattern(path), builtIn: false))
        }
    }

    /// True when an enabled rule skips exactly this folder.
    public func isSkipped(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pattern = BackupNotes.escapedPattern(path)
        return state.settings.rules.contains { $0.enabled && $0.pattern(home: home) == pattern }
    }

    /// Forgets a single-item answer, so the item is asked about again after the next backup.
    public func forgetChoice(path: String) {
        updateSettings { $0.pathChoices[path] = nil }
    }

    private func notifyBackupFinished(_ r: BackupRecord, disk: KnownDisk, ejected: Bool, ejectProblem: Bool) {
        switch r.outcome {
        case .success, .warning:
            guard r.trigger != .scheduled, state.settings.notifyOnSuccess else { return }
            let files = r.stats.map { "\($0.fileCount.formatted()) files checked. " } ?? ""
            let tail = ejected ? "\(disk.name) was ejected. You can unplug it."
                : ejectProblem ? "\(disk.name) could not be ejected because files on it are in use."
                : "\(disk.name) is up to date."
            let title = r.outcome == .warning ? "Backup finished with notes" : "Backup finished"
            notifier.post(title: title, body: files + tail, id: "backup-\(disk.id)", sound: true)
        case .failed:
            // Servers are often out of reach, for example while travelling. The menu bar shows the error
            // and the stale reminder covers long gaps, so scheduled server failures stay quiet.
            if r.trigger == .scheduled, disk.isRemote { return }
            notifier.post(title: "Backup failed", body: r.messages.first ?? "Something went wrong.", id: "backup-\(disk.id)", sound: true)
        case .cancelled:
            break
        }
    }

    // MARK: - Verification

    public func startVerification(diskID: String) {
        guard activity.isIdle, let engine, let disk = disk(diskID) else { return }
        let volume: VolumeInfo?
        do { volume = try access(to: disk) } catch { return }
        activity = .verifying(diskID: diskID, "Starting…")
        beginKeepAwake("Checking backups on \(disk.name)")
        currentTask = Task {
            defer { endKeepAwake() }
            do {
                let summary = try await engine.verify(disk: disk, on: volume) { [weak self] text in
                    Task { @MainActor in
                        if case .verifying(let id, _) = self?.activity { self?.activity = .verifying(diskID: id, text) }
                    }
                }
                updateDisk(diskID) { $0.lastVerification = summary }
                if !summary.passed {
                    notifier.post(title: "Backup check found a problem", body: summary.problems.first ?? "Open Nine Lives for details.",
                                  id: "verify-\(diskID)", sound: true)
                }
            } catch {
                if !(Task.isCancelled || error is CancellationError) {
                    let summary = VerificationSummary(date: Date(), repositoryOK: false, filesRestored: 0, problems: [Self.friendly(error)])
                    updateDisk(diskID) { $0.lastVerification = summary }
                }
            }
            activity = .idle
            currentTask = nil
        }
    }

    // MARK: - Restore support

    private func exclusive<T>(_ description: String, _ work: (BackupEngine) async throws -> T) async throws -> T {
        guard let engine else { throw EngineError.engineMissing }
        guard activity.isIdle else { throw EngineError.busy }
        activity = .working(description)
        beginKeepAwake(description)
        defer { endKeepAwake(); activity = .idle }
        return try await work(engine)
    }

    public func archives(for disk: KnownDisk) async throws -> [ArchiveInfo] {
        let v = try access(to: disk)
        return try await exclusive("Reading backups…") { try await $0.archives(disk: disk, on: v) }
    }

    public func catalog(for archive: ArchiveInfo, disk: KnownDisk, progress: @escaping @Sendable (Int) -> Void) async throws -> Catalog {
        if let cached = engine?.catalogs.cached(archiveID: archive.id) { return cached }
        let v = try access(to: disk)
        return try await exclusive("Reading backup contents…") {
            try await $0.catalog(for: archive, disk: disk, on: v, progress: progress)
        }
    }

    @discardableResult
    public func restore(entries: [CatalogEntry], from archive: ArchiveInfo, disk: KnownDisk, target: RestoreTarget) async throws -> URL {
        let v = try access(to: disk)
        return try await exclusive("Restoring…") {
            try await $0.restore(entries: entries, from: archive, disk: disk, on: v, target: target)
        }
    }

    // MARK: - Status

    public var latestSuccess: Date? { state.disks.compactMap(\.lastBackup).max() }

    public var status: OverallStatus {
        if state.disks.isEmpty { return .needsSetup }
        switch activity {
        case .backingUp: return .running("Backing up…")
        case .verifying: return .running("Checking backups…")
        case .working(let t): return .running(t)
        case .idle: break
        }
        if let last = state.history.first, last.outcome == .failed {
            return .error(last.messages.first ?? "The last backup failed.")
        }
        switch Policy.staleness(disks: state.disks, now: Date(), remindAfterDays: state.settings.remindAfterDays) {
        case .neverBackedUp: return .warning("No backup yet")
        case .stale(let d): return .warning("Last backup \(d) days ago")
        case .fresh: break
        }
        if let d = state.disks.first(where: { $0.lastVerification?.passed == false }) {
            return .warning("The check of \(d.name) found a problem")
        }
        return .ok(latestSuccess ?? Date())
    }

    static func friendly(_ error: Error) -> String {
        error.localizedDescription
    }

    /// Technical output behind an error, if there is any.
    nonisolated public static func details(_ error: Error) -> String? { (error as? ResticError)?.details }
}
