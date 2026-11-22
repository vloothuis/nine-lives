import Foundation
import Testing
import BorgKit
@testable import NineLivesCore

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nl-core-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

@Suite struct PolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func backupDue() {
        #expect(Policy.isBackupDue(lastBackup: nil, now: now, intervalMinutes: 60))
        #expect(!Policy.isBackupDue(lastBackup: now.addingTimeInterval(-30 * 60), now: now, intervalMinutes: 60))
        #expect(Policy.isBackupDue(lastBackup: now.addingTimeInterval(-61 * 60), now: now, intervalMinutes: 60))
    }

    @Test func stalenessWithRotatingDisks() {
        var a = KnownDisk(id: "a", name: "A", mode: .authenticated, diskEncrypted: true, repoFolder: "x")
        var b = KnownDisk(id: "b", name: "B", mode: .authenticated, diskEncrypted: true, repoFolder: "x")
        #expect(Policy.staleness(disks: [], now: now, remindAfterDays: 7) == .fresh)
        #expect(Policy.staleness(disks: [a, b], now: now, remindAfterDays: 7) == .neverBackedUp)
        a.lastBackup = now.addingTimeInterval(-20 * 86_400)
        b.lastBackup = now.addingTimeInterval(-2 * 86_400)
        // One recent disk is enough.
        #expect(Policy.staleness(disks: [a, b], now: now, remindAfterDays: 7) == .fresh)
        b.lastBackup = now.addingTimeInterval(-9 * 86_400)
        #expect(Policy.staleness(disks: [a, b], now: now, remindAfterDays: 7) == .stale(days: 9))
        #expect(Policy.neglectedDisks(disks: [a, b], now: now, afterDays: 14).map(\.id) == ["a"])
    }

    @Test func verificationDue() {
        #expect(Policy.isVerificationDue(last: nil, now: now, everyDays: 30))
        let recent = VerificationSummary(date: now.addingTimeInterval(-86_400), repositoryOK: true, filesRestored: 5, problems: [])
        #expect(!Policy.isVerificationDue(last: recent, now: now, everyDays: 30))
        #expect(!Policy.isVerificationDue(last: nil, now: now, everyDays: 0))
    }

    @Test func batteryRules() {
        #expect(Policy.canRunOnPower(onBattery: false, percent: 5, pauseOnLowBattery: true))
        #expect(!Policy.canRunOnPower(onBattery: true, percent: 10, pauseOnLowBattery: true))
        #expect(Policy.canRunOnPower(onBattery: true, percent: 50, pauseOnLowBattery: true))
        #expect(Policy.canRunOnPower(onBattery: true, percent: 5, pauseOnLowBattery: false))
    }

    @Test func reminderRateLimit() {
        #expect(Policy.shouldReminder(now: now, lastReminder: nil))
        #expect(!Policy.shouldReminder(now: now, lastReminder: now.addingTimeInterval(-3600)))
        #expect(Policy.shouldReminder(now: now, lastReminder: now.addingTimeInterval(-90_000)))
    }
}

@Suite struct SettingsTests {
    @Test func patterns() {
        let s = BackupSettings(sources: ["/Users/me"])
        let p = s.excludePatterns(home: "/Users/me")
        #expect(p.contains("pp:/Users/me/.Trash"))
        #expect(p.contains("fm:*/node_modules"))
        #expect(p.contains("pp:/Users/me/Library/Application Support/Nine Lives/Borg"))
    }

    @Test func disabledRulesAreSkipped() {
        var s = BackupSettings()
        for i in s.rules.indices { s.rules[i].enabled = false }
        let p = s.excludePatterns(home: "/h")
        #expect(p.count == DefaultRules.always.count)
    }

    @Test func storeRoundTripAndMerge() throws {
        let dir = try tempDir()
        let store = StateStore(directory: dir)
        var state = AppState()
        state.onboardingComplete = true
        state.settings.rules.removeAll { $0.id == "trash" }
        state.disks = [KnownDisk(id: "u", name: "Disk", mode: .repokey, diskEncrypted: false, repoFolder: "r")]
        store.save(state)
        let loaded = store.load()
        #expect(loaded.onboardingComplete)
        #expect(loaded.disks.first?.name == "Disk")
        // Rules removed from a saved file come back as new defaults.
        #expect(loaded.settings.rules.contains { $0.id == "trash" })
    }

    @Test func passphraseFormat() {
        let p = PassphraseGenerator.generate()
        #expect(p.split(separator: "-").count == 6)
        #expect(p.count == 29)
        #expect(p != PassphraseGenerator.generate())
    }
}

func fakeVolume(at url: URL, encrypted: Bool) -> VolumeInfo {
    VolumeInfo(uuid: "TEST-\(UUID().uuidString)", url: url, name: "Test Disk", filesystem: "apfs",
               totalCapacity: 100_000_000_000, availableCapacity: 50_000_000_000, isEncrypted: encrypted,
               isInternal: false, isWritable: true, busProtocol: "USB")
}

@Suite struct EngineTests {
    func makeEngine(_ root: URL) throws -> (BackupEngine, MemorySecretStore) {
        guard let bin = BorgBinary.locate(bundleResources: nil) else { throw CancellationError() }
        let secrets = MemorySecretStore()
        let engine = BackupEngine(
            borg: Borg(binary: bin, baseDirectory: root.appendingPathComponent("borg")),
            secrets: secrets,
            catalogs: CatalogStore(directory: root.appendingPathComponent("catalogs")))
        return (engine, secrets)
    }

    @Test func fullLifecycleOnEncryptedDisk() async throws {
        let root = try tempDir()
        let (engine, _) = try makeEngine(root)
        let disk = root.appendingPathComponent("disk")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Caches/app"), withIntermediateDirectories: true)
        try "report".write(to: home.appendingPathComponent("Documents/report.txt"), atomically: true, encoding: .utf8)
        try "cache".write(to: home.appendingPathComponent("Library/Caches/app/blob"), atomically: true, encoding: .utf8)

        let volume = fakeVolume(at: disk, encrypted: true)
        #expect(await engine.probeExisting(on: volume) == .none)
        let known = try await engine.createDisk(on: volume, passphrase: nil)
        #expect(known.mode == .authenticated)
        #expect(await engine.probeExisting(on: volume) == .openable)
        #expect(FileManager.default.fileExists(atPath: disk.appendingPathComponent("Nine Lives Backups/HOW TO RESTORE.txt").path))

        var settings = BackupSettings(sources: [home.path])
        settings.rules = DefaultRules.all
        // The engine builds patterns from NSHomeDirectory(); add an explicit rule for the fake home.
        settings.rules.append(ExcludeRule(id: "t", title: "t", detail: "", kind: .absolute,
                                          value: home.path + "/Library/Caches", builtIn: false))
        let result = try await engine.runBackup(disk: known, on: volume, settings: settings, progress: { _ in })
        #expect(result.create.stats.fileCount >= 1)

        let archives = try await engine.archives(disk: known, on: volume)
        #expect(archives.count == 1)
        let catalog = try await engine.catalog(for: archives[0], disk: known, on: volume, progress: { _ in })

        // Browse the tree from the top level down to the file.
        var path = ""
        for component in home.path.split(separator: "/") {
            let kids = catalog.children(of: path)
            path = path.isEmpty ? String(component) : path + "/" + component
            #expect(kids.contains { $0.path == path && $0.isDirectory })
        }
        #expect(catalog.children(of: path).contains { $0.name == "Documents" })
        let found = catalog.search("report")
        #expect(found.count == 1)
        #expect(!catalog.search("blob").contains { $0.path.contains("Library/Caches") })

        let restoreRoot = root.appendingPathComponent("restore")
        let out = try await engine.restore(entries: found, from: archives[0], disk: known, on: volume, target: .folder(restoreRoot))
        #expect(try String(contentsOf: out.appendingPathComponent("report.txt"), encoding: .utf8) == "report")

        let summary = try await engine.verify(disk: known, on: volume, status: { _ in })
        #expect(summary.passed)
        #expect(summary.filesRestored >= 1)

        // A second run keeps one archive per hour window; both exist before pruning rules apply.
        _ = try await engine.runBackup(disk: known, on: volume, settings: settings, progress: { _ in })
    }

    @Test func unencryptedDiskNeedsPassphraseAndAdopts() async throws {
        let root = try tempDir()
        let (engine, secrets) = try makeEngine(root)
        let disk = root.appendingPathComponent("disk")
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        let volume = fakeVolume(at: disk, encrypted: false)

        do {
            _ = try await engine.createDisk(on: volume, passphrase: nil)
            Issue.record("expected missing passphrase")
        } catch let e as EngineError {
            #expect(e == .missingPassphrase("Test Disk"))
        }

        let pass = PassphraseGenerator.generate()
        let known = try await engine.createDisk(on: volume, passphrase: pass)
        #expect(known.mode == .repokey)
        #expect(secrets.passphrase(for: volume.id) == pass)

        // Simulate a reinstalled Mac: the keychain item is gone.
        secrets.removePassphrase(for: volume.id)
        #expect(await engine.probeExisting(on: volume) == .needsPassphrase)
        do {
            _ = try await engine.adoptDisk(on: volume, passphrase: "wrong")
            Issue.record("expected wrong passphrase")
        } catch let e as BorgError {
            #expect(e.isWrongPassphrase)
        }
        let adopted = try await engine.adoptDisk(on: volume, passphrase: pass)
        #expect(adopted.mode == .repokey)
        #expect(secrets.passphrase(for: volume.id) == pass)
    }

    @Test func refusesReadOnlyAndFullDisks() async throws {
        let root = try tempDir()
        let (engine, _) = try makeEngine(root)
        var volume = fakeVolume(at: root, encrypted: true)
        let disk = KnownDisk(id: volume.id, name: "Test Disk", mode: .authenticated, diskEncrypted: true, repoFolder: "r")
        volume.isWritable = false
        do {
            _ = try await engine.runBackup(disk: disk, on: volume, settings: BackupSettings(), progress: { _ in })
            Issue.record("expected failure")
        } catch let e as EngineError { #expect(e == .diskReadOnly("Test Disk")) }
        volume.isWritable = true
        volume.availableCapacity = 1000
        do {
            _ = try await engine.runBackup(disk: disk, on: volume, settings: BackupSettings(), progress: { _ in })
            Issue.record("expected failure")
        } catch let e as EngineError { #expect(e == .diskFull("Test Disk")) }
    }
}

@Suite struct CompatibilityTests {
    @Test func partialStateFileStillLoads() throws {
        let dir = try tempDir()
        try #"{"settings":{"sources":["/tmp/x"]},"onboardingComplete":true}"#
            .write(to: dir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        let s = StateStore(directory: dir).load()
        #expect(s.onboardingComplete)
        #expect(s.settings.sources == ["/tmp/x"])
        #expect(s.settings.intervalMinutes == 60)
        #expect(!s.settings.rules.isEmpty)
    }
}

@Suite struct ServerTests {
    @Test func serverTracebackIsSummarised() {
        let e = BorgError(exitCode: 2, messages: ["Borg server: Platform: Linux pi4", "Borg server: Borg: 1.2.4 Python: CPython 3.11.2", "SSH_ORIGINAL_COMMAND: None"])
        #expect(e.summary.count < 150)
        #expect(!e.summary.contains("Platform"))
        #expect(e.details?.contains("Linux pi4") == true)
    }

    @Test func locationFormatsHomeRelativeAndAbsolutePaths() {
        #expect(RemoteServer(host: "nas.local", user: "me", path: "backups/mac").location == "ssh://me@nas.local:22/./backups/mac")
        #expect(RemoteServer(host: "h", user: "u", port: 2222, path: "/srv/b").location == "ssh://u@h:2222/srv/b")
        #expect(RemoteServer(host: "::1", user: "u", path: "x").location == "ssh://u@[::1]:22/./x")
    }

    @Test func errorsAreClassified() {
        #expect(BorgError(exitCode: 2, rawMessages: ["me@h: Permission denied (publickey)."]).isAuthenticationFailure)
        #expect(BorgError(exitCode: 2, msgid: "ConnectionClosedWithHint").isConnectionProblem)
        #expect(BorgError(exitCode: 2, rawMessages: ["ssh: Could not resolve hostname nas"]).isConnectionProblem)
        #expect(BorgError(exitCode: 2, rawMessages: ["bash: borg: command not found"]).isBorgMissingOnServer)
        #expect(!BorgError(exitCode: 2, msgid: "Repository.DoesNotExist").isConnectionProblem)
    }

    @Test func failedAttemptsWaitBeforeRetrying() {
        let now = Date()
        #expect(!Policy.isBackupDue(lastBackup: nil, now: now, intervalMinutes: 60, lastFailure: now.addingTimeInterval(-300)))
        #expect(Policy.isBackupDue(lastBackup: nil, now: now, intervalMinutes: 60, lastFailure: now.addingTimeInterval(-1200)))
    }

    @Test func oldStateWithoutServerFieldsLoads() throws {
        let json = #"{"disks":[{"id":"A","name":"D","mode":"repokey-blake2","diskEncrypted":false,"repoFolder":"x","addedAt":"2026-01-01T00:00:00Z"}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(AppState.self, from: Data(json.utf8))
        #expect(state.disks.first?.remote == nil)
    }

    /// Needs a reachable sshd. Set NINELIVES_TEST_SSH to "port:authorized_keys_file". Skipped otherwise.
    @Test func serverLifecycleOverSSH() async throws {
        guard let cfg = ProcessInfo.processInfo.environment["NINELIVES_TEST_SSH"] else { return }
        let parts = cfg.split(separator: ":").map(String.init)
        let port = Int(parts[0])!
        let authorizedKeys = URL(fileURLWithPath: parts[1])
        let root = try tempDir()
        guard let bin = BorgBinary.locate(bundleResources: nil) else { return }
        let keys = SSHKeyStore(directory: root.appendingPathComponent("ssh"))
        let pub = try keys.ensureKey()
        let secrets = MemorySecretStore()
        let engine = BackupEngine(
            borg: Borg(binary: bin, baseDirectory: root.appendingPathComponent("borg"), ssh: keys.options),
            secrets: secrets, catalogs: CatalogStore(directory: root.appendingPathComponent("catalogs")))
        // Borg is not on sshd's default PATH, so give its full path like a user would.
        let server = RemoteServer(host: "127.0.0.1", user: NSUserName(), port: port,
                                  path: "/tmp/nlssh/repos/\(UUID().uuidString)", borgPath: bin.path)

        try "".write(to: authorizedKeys, atomically: true, encoding: .utf8)
        #expect(await engine.probeServer(server) == .rejectedKey)
        try (pub + "\n").write(to: authorizedKeys, atomically: true, encoding: .utf8)
        #expect(await engine.probeServer(server) == .noRepository)
        let bad = RemoteServer(host: "127.0.0.1", user: NSUserName(), port: port, path: server.path, borgPath: "/nonexistent/borg")
        let badProbe = await engine.probeServer(bad)
        #expect(badProbe != .noRepository && badProbe != .openable)

        let known = try await engine.createServer(server, passphrase: "test pass")
        #expect(known.isRemote)
        #expect(await engine.probeServer(server) == .needsPassphrase)
        #expect(await engine.probeServer(server, passphrase: "test pass") == .openable)

        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "remote hello".write(to: home.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let result = try await engine.runBackup(disk: known, on: nil, settings: BackupSettings(sources: [home.path]), progress: { _ in })
        #expect(result.create.stats.fileCount >= 1)

        let archives = try await engine.archives(disk: known, on: nil)
        #expect(archives.count == 1)
        let catalog = try await engine.catalog(for: archives[0], disk: known, on: nil, progress: { _ in })
        let found = catalog.search("hello")
        #expect(found.count == 1)
        let out = try await engine.restore(entries: found, from: archives[0], disk: known, on: nil, target: .folder(root.appendingPathComponent("r")))
        #expect(try String(contentsOf: out.appendingPathComponent("hello.txt"), encoding: .utf8) == "remote hello")
        let summary = try await engine.verify(disk: known, on: nil, status: { _ in })
        #expect(summary.passed)

        // A fresh Mac connects to the existing repository with the passphrase.
        let adopted = try await engine.adoptServer(server, passphrase: "test pass")
        #expect(adopted.lastBackup != nil)
    }
}
