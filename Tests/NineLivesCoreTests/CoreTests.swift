import Foundation
import Testing
import ResticKit
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
        #expect(p.contains("/Users/me/.Trash"))
        #expect(p.contains("node_modules"))
        #expect(p.contains("/Users/me/Library/Application Support/Nine Lives/Restic"))
    }

    @Test func defaultRuleIDsAreUnique() {
        let ids = DefaultRules.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func markerRulesAreNotPatterns() {
        let s = BackupSettings()
        #expect(s.excludeMarkers.contains("pyvenv.cfg"))
        #expect(!s.excludePatterns(home: "/h").contains { $0.contains("pyvenv.cfg") })
    }

    @Test func askRulesSkipUntilAnswered() {
        let s = BackupSettings()
        let r = s.rules.first { $0.value == "VirtualBox VMs" }
        #expect(r?.ask == true)
        #expect(r?.enabled == true)
        #expect(s.rules.first { $0.value == ".rustup/toolchains" }?.ask == false)
        #expect(s.rules.first { $0.value == ".next" }?.enabled == true)
    }

    @Test func oldRulesWithoutCategoryStillDecode() throws {
        let json = #"{"id":"x","title":"t","detail":"","kind":"home","value":"v","enabled":true,"builtIn":false}"#
        let r = try JSONDecoder().decode(ExcludeRule.self, from: Data(json.utf8))
        #expect(r.category == ExcludeRule.defaultCategory)
    }

    @Test func scannerFindsLargeItemsOnce() throws {
        let home = try tempDir().path
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/Documents/vm.pvm", withIntermediateDirectories: true)
        try Data(count: 3_000_000).write(to: URL(fileURLWithPath: home + "/Documents/vm.pvm/disk.hdd"))
        try fm.createDirectory(atPath: home + "/.colima", withIntermediateDirectories: true)
        try Data(count: 10).write(to: URL(fileURLWithPath: home + "/.colima/tiny"))
        let rules = BackupSettings().rules
        let found = OptionalScanner.scan(rules: rules, answered: [], sources: [home], home: home, minimumSize: 1_000_000)
        #expect(found.map(\.id) == ["anywhere:*.pvm"] || found.contains { $0.title == "Parallels machines" })
        #expect(!found.contains { $0.paths.contains { $0.hasSuffix(".colima") } })
        let again = OptionalScanner.scan(rules: rules, answered: found.map(\.id), sources: [home], home: home, minimumSize: 1_000_000)
        #expect(again.isEmpty)
    }

    @Test func pathChoicesBecomePatterns() {
        var s = BackupSettings()
        s.pathChoices = ["/h/a.pvm": true, "/h/b.pvm": false]
        #expect(s.includePatterns == ["/h/a.pvm"])
        #expect(s.excludePatterns(home: "/h").contains("/h/b.pvm"))
    }

    @Test func scannerGroupsItemsAndSkipsAnsweredPaths() throws {
        let home = try tempDir().path
        let fm = FileManager.default
        for n in ["a", "b"] {
            try fm.createDirectory(atPath: home + "/Documents/\(n).pvm", withIntermediateDirectories: true)
            try Data(count: 2_000_000).write(to: URL(fileURLWithPath: home + "/Documents/\(n).pvm/disk"))
        }
        let rules = BackupSettings().rules
        let all = OptionalScanner.scan(rules: rules, answered: [], sources: [home], home: home, minimumSize: 1_000_000)
        #expect(all.count == 1)
        #expect(all.first?.items.count == 2)
        let paths = try #require(all.first).paths
        let rest = OptionalScanner.scan(rules: rules, answered: [], answeredPaths: [paths[0]],
                                        sources: [home], home: home, minimumSize: 1_000_000)
        #expect(rest.first?.paths == [paths[1]])
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
        guard let bin = ResticBinary.locate(bundleResources: nil) else { throw CancellationError() }
        let secrets = MemorySecretStore()
        let engine = BackupEngine(
            restic: Restic(binary: bin, cacheDirectory: root.appendingPathComponent("cache")),
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
        #expect(FileManager.default.fileExists(atPath: disk.appendingPathComponent("Nine Lives Backups/\(Machine.folderName) password.txt").path))

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
        } catch let e as ResticError {
            #expect(e.isWrongPassphrase)
        }
        let adopted = try await engine.adoptDisk(on: volume, passphrase: pass)
        #expect(adopted.mode == .repokey)
        #expect(secrets.passphrase(for: volume.id) == pass)
    }

    /// Writes a folder that looks like a borg repository.
    func fakeBorgRepo(at url: URL, size: Int = 1000) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("data"), withIntermediateDirectories: true)
        try "[repository]\nversion = 1\n".write(to: url.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try Data(count: size).write(to: url.appendingPathComponent("data/0"))
    }

    @Test func migratesBorgDiskNextToOldBackups() async throws {
        let root = try tempDir()
        let (engine, secrets) = try makeEngine(root)
        let disk = root.appendingPathComponent("disk")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "doc".write(to: home.appendingPathComponent("doc.txt"), atomically: true, encoding: .utf8)
        let volume = fakeVolume(at: disk, encrypted: false)
        try fakeBorgRepo(at: disk.appendingPathComponent("NL/mac"))
        try secrets.setPassphrase("kept pass", for: volume.id)
        var old = KnownDisk(id: volume.id, name: "Test Disk", mode: .repokey, diskEncrypted: false, repoFolder: "NL/mac")
        old.format = nil
        old.repositoryID = "borg-id"

        let m = try await engine.migrate(disk: old, on: volume)
        #expect(m.warning == nil)
        #expect(m.disk.repoFolder == "NL/mac-restic")
        #expect(m.disk.legacyFolder == "NL/mac")
        #expect(!m.disk.needsMigration)
        #expect(BackupEngine.isBorgRepository(at: disk.appendingPathComponent("NL/mac")))

        let r = try await engine.runBackup(disk: m.disk, on: volume, settings: BackupSettings(sources: [home.path]), progress: { _ in })
        #expect(r.disk.repoFolder == "NL/mac")
        #expect(r.disk.legacyFolder == nil)
        #expect(!BackupEngine.isBorgRepository(at: disk.appendingPathComponent("NL/mac")))
        #expect(!FileManager.default.fileExists(atPath: disk.appendingPathComponent("NL/mac-restic").path))
        // The passphrase is kept and opens the moved repository.
        #expect(secrets.passphrase(for: volume.id) == "kept pass")
        #expect(try await engine.archives(disk: r.disk, on: volume).count == 1)
    }

    @Test func migrationRemovesOldBackupsWhenSpaceIsShort() async throws {
        let root = try tempDir()
        let (engine, _) = try makeEngine(root)
        let disk = root.appendingPathComponent("disk")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "doc".write(to: home.appendingPathComponent("doc.txt"), atomically: true, encoding: .utf8)
        var volume = fakeVolume(at: disk, encrypted: true)
        volume.availableCapacity = 250_000_000
        try fakeBorgRepo(at: disk.appendingPathComponent("NL/mac"), size: 100_000_000)
        var old = KnownDisk(id: volume.id, name: "Test Disk", mode: .authenticated, diskEncrypted: true, repoFolder: "NL/mac")
        old.format = .borg

        let m = try await engine.migrate(disk: old, on: volume)
        #expect(m.warning != nil)
        #expect(m.disk.repoFolder == "NL/mac")
        #expect(m.disk.legacyFolder == nil)
        #expect(FileManager.default.fileExists(atPath: disk.appendingPathComponent("NL/mac password.txt").path))
        let r = try await engine.runBackup(disk: m.disk, on: volume, settings: BackupSettings(sources: [home.path]), progress: { _ in })
        #expect(r.create.stats.fileCount >= 1)
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
    @Test func errorsAreClassified() {
        #expect(ResticError(exitCode: 1, rawMessages: ["me@h: Permission denied (publickey)."]).isAuthenticationFailure)
        #expect(ResticError(exitCode: 1, rawMessages: ["ssh: Could not resolve hostname nas"]).isConnectionProblem)
        #expect(ResticError(exitCode: 1, rawMessages: ["subsystem request failed on channel 0"]).isSFTPMissing)
        #expect(ResticError(exitCode: 10, messages: ["Fatal: repository does not exist"]).isRepositoryMissing)
        #expect(!ResticError(exitCode: 10).isConnectionProblem)
    }

    @Test func oldStateNeedsMigration() throws {
        let json = #"{"disks":[{"id":"A","name":"D","mode":"repokey-blake2","diskEncrypted":false,"repoFolder":"x","addedAt":"2026-01-01T00:00:00Z","remote":{"host":"h","user":"u","port":22,"path":"p","borgPath":"/usr/bin/borg"}}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(AppState.self, from: Data(json.utf8))
        #expect(state.disks.first?.needsMigration == true)
        #expect(state.disks.first?.remote?.path == "p")
        #expect(!KnownDisk(id: "n", name: "n", mode: .repokey, diskEncrypted: false, repoFolder: "r").needsMigration)
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
        guard let bin = ResticBinary.locate(bundleResources: nil) else { return }
        let keys = SSHKeyStore(directory: root.appendingPathComponent("ssh"))
        let pub = try keys.ensureKey()
        let secrets = MemorySecretStore()
        let engine = BackupEngine(
            restic: Restic(binary: bin, cacheDirectory: root.appendingPathComponent("cache"), ssh: keys.options),
            secrets: secrets, catalogs: CatalogStore(directory: root.appendingPathComponent("catalogs")))
        let server = RemoteServer(host: "127.0.0.1", user: NSUserName(), port: port,
                                  path: "/tmp/nlssh/repos/\(UUID().uuidString)")

        try "".write(to: authorizedKeys, atomically: true, encoding: .utf8)
        #expect(await engine.probeServer(server) == .rejectedKey)
        try (pub + "\n").write(to: authorizedKeys, atomically: true, encoding: .utf8)
        #expect(await engine.probeServer(server) == .noRepository)

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

@Suite struct CurrentResultsTests {
    func rec(_ disk: String, _ outcome: BackupRecord.Outcome, _ messages: [String] = ["m"], at t: TimeInterval) -> BackupRecord {
        BackupRecord(diskID: disk, diskName: disk, start: Date(timeIntervalSince1970: t), end: Date(timeIntervalSince1970: t),
                     outcome: outcome, messages: messages, trigger: .manual)
    }

    @Test func latestPerDiskNewestFirst() {
        // History is newest first.
        let h = [rec("pi", .failed, at: 5), rec("usb", .warning, at: 4), rec("pi", .success, [], at: 3), rec("usb", .failed, at: 2)]
        let r = BackupCoordinator.currentResults(history: h, disks: ["pi", "usb"], running: nil)
        #expect(r.map(\.diskID) == ["pi", "usb"])
        #expect(r.map(\.outcome) == [.failed, .warning])
    }

    @Test func runningDiskIsHidden() {
        let h = [rec("pi", .failed, at: 5), rec("usb", .failed, at: 4)]
        let r = BackupCoordinator.currentResults(history: h, disks: ["pi", "usb"], running: "pi")
        #expect(r.map(\.diskID) == ["usb"])
    }

    @Test func successWithoutMessagesClearsOlderFailure() {
        let h = [rec("pi", .success, [], at: 5), rec("pi", .failed, at: 4)]
        #expect(BackupCoordinator.currentResults(history: h, disks: ["pi"], running: nil).isEmpty)
    }

    @Test func cancelledFallsBackAndRemovedDisksAreLeftOut() {
        let h = [rec("pi", .cancelled, at: 5), rec("pi", .failed, at: 4), rec("old", .failed, at: 3)]
        let r = BackupCoordinator.currentResults(history: h, disks: ["pi"], running: nil)
        #expect(r.map(\.outcome) == [.failed])
    }
}

@Suite struct BackupNotesTests {
    @Test func groupsByFolderAndCause() {
        let groups = BackupNotes.group([
            "openfile for readdirnames failed: open /Users/a/.ansible/tmp/ansible-local-1: permission denied",
            "openfile for readdirnames failed: open /Users/a/.ansible/tmp/ansible-local-2: permission denied",
            "open /Users/a/Library/Mail/V10: operation not permitted",
            "lstat /Users/a/gone.txt: no such file or directory",
            "something odd",
        ])
        #expect(groups.count == 3)
        #expect(groups[0].cause == .unreadable)
        #expect(groups[0].folder == "/Users/a/.ansible/tmp")
        #expect(groups[0].paths.count == 2)
        #expect(groups[1].cause == .protected)
        #expect(groups[2].cause == .other)
    }

    @Test func busyAndOtherItemErrorsCanBeSkipped() {
        let groups = BackupNotes.group([
            "read /Users/a/Library/Containers/com.x/Data: interrupted system call",
            "read /Users/a/Library/Containers/com.y/Data: interrupted system call",
            "read /Users/a/w/build/ModuleCache.noindex/D5Y: too many open files in system",
            "read /Users/a/odd/thing: not a folder",
            "The backup disk at /Volumes/Backup: needs maintenance",
        ], home: "/Users/a")
        #expect(groups.map(\.cause) == [.busy, .busy, .busy, .other, .other])
        // Busy errors are not merged into a pattern.
        #expect(groups[0].folder == "/Users/a/Library/Containers/com.x")
        #expect(groups[2].folder == "/Users/a/w/build/ModuleCache.noindex")
        #expect(groups[3].folder == "/Users/a/odd")
        #expect(BackupNotes.canSkip(groups[3], home: "/Users/a"))
        // Free text is never read as a path.
        #expect(groups[4].folder == nil)
        #expect(!BackupNotes.canSkip(groups[4], home: "/Users/a"))
    }

    @Test func withoutIndexMergesFoldersThatDifferInOneName() {
        let groups = BackupNotes.group([
            "open /Users/a/FP/AB-1/wharf/tombstone/x: permission denied",
            "open /Users/a/FP/CD-2/wharf/tombstone/y: permission denied",
            "open /Users/a/FP/EF-3/wharf/tombstone/z: permission denied",
            "open /Users/a/Projects/one/f: permission denied",
            "open /Users/a/Projects/two/f: permission denied",
            "open /Users/a/X/p/q/t/f: permission denied",
            "open /Users/a/X/r/s/t/f: permission denied",
        ], home: "/Users/a")
        #expect(groups.count == 5)
        #expect(groups[0].folder == "/Users/a/FP/*/wharf/tombstone")
        #expect(groups[0].pattern == "/Users/a/FP/*/wharf/tombstone")
        #expect(groups[0].folders.count == 3)
        #expect(groups[0].extra == nil)
        #expect(BackupNotes.canSkip(groups[0], home: "/Users/a"))
        #expect(groups[1].folders == ["/Users/a/Projects/one"])
    }

    @Test func generalizeKeepsSharedStartAndEnd() {
        let c = BackupNotes.generalize(["/t/ansible-local-8f3a2/x", "/t/ansible-local-91bc0/x"])
        #expect(c?.pattern == "/t/ansible-local-*/x")
        #expect(c?.slots == 1)
        #expect(BackupNotes.generalize(["/a/x", "/a/y"]) == nil)
        #expect(BackupNotes.generalize(["/a/b/x", "/a/x"]) == nil)
        #expect(BackupNotes.generalize(["/a/[1]/x", "/a/[2]/x"])?.pattern == "/a/\\[*\\]/x")
        #expect(!BackupNotes.canSkip(prefixOf: "/Users/*/x", home: "/Users/a"))
        #expect(!BackupNotes.canSkip(prefixOf: "/Users/a/*/x", home: "/Users/a"))
        #expect(BackupNotes.canSkip(prefixOf: "/Users/a/b/*/x", home: "/Users/a"))
    }

    private func index(_ files: [String], unreadable: [String] = []) -> FolderIndex {
        let c = FolderCollector()
        for f in files {
            c.addVerboseLine(#"{"message_type":"verbose_status","action":"new","item":"\#(f)","data_size":1}"#)
        }
        for u in unreadable { c.addUnreadable(u) }
        let built = FolderIndex(c, snapshotID: "abcdef0123")
        return FolderIndex(data: built.data())!
    }

    @Test func indexRoundTripsAndCounts() {
        let i = index(["/h/a/1", "/h/a/2", "/h/a/b/3", "/h/a/b/", "/h/a/", "/h/c/4"])
        #expect(i.snapshotID == "abcdef0123")
        let a = i.node(at: "/h/a")!
        #expect(i.items[a] == 4)
        #expect(i.matches("/h/*").count == 2)
        #expect(i.matches("/h/a/b").count == 1)
        #expect(i.node(at: "/h/zz") == nil)
        #expect(FolderIndex(data: Data([1, 2, 3])) == nil)
    }

    @Test func indexDecidesHowBroadAPatternMayBe() {
        var files: [String] = []
        for u in ["U1", "U2", "U3"] { files += ["/h/FP/\(u)/srv1/tombstone/", "/h/FP/\(u)/srv2/tombstone/"] }
        // A sibling folder with real content that a broad pattern would catch.
        files += (0..<50).map { "/h/Work/proj/tombstone/f\($0)" }
        let i = index(files, unreadable: ["/h/FP/U1/srv1/tombstone/x", "/h/FP/U2/srv2/tombstone/x", "/h/FP/U3/srv1/tombstone/x"])
        let groups = BackupNotes.group([
            "open /h/FP/U1/srv1/tombstone/x: permission denied",
            "open /h/FP/U2/srv2/tombstone/x: permission denied",
            "open /h/FP/U3/srv1/tombstone/x: permission denied",
        ], index: i, home: "/h")
        #expect(groups.count == 1)
        #expect(groups[0].pattern == "/h/FP/U*/srv*/tombstone")
        #expect(groups[0].extra == FolderIndex.Extra(folders: 3, items: 3, unknown: false))

        // Without index entries for the failing folders, the index is not trusted for merging.
        #expect(i.extra(of: "/h/*/*/tombstone", besides: ["/h/nope"]) == nil)
        let broad = i.extra(of: "/h/*/*/tombstone", besides: ["/h/FP/U1/srv1/tombstone"])!
        #expect(broad.items > BackupNotes.extraBudget)
    }

    @Test func lastNameMayDifferOnlyWhenTheIndexAllowsIt() {
        var files = ["/h/t/ansible-local-1x/f", "/h/t/ansible-local-2y/f"]
        files += (0..<20).map { "/h/P/\($0 % 4)/f\($0)" }
        let i = index(files, unreadable: ["/h/t/ansible-local-1x/f", "/h/t/ansible-local-2y/f"])
        let a = BackupNotes.group(["open /h/t/ansible-local-1x/f: permission denied",
                                   "open /h/t/ansible-local-2y/f: permission denied"], index: i, home: "/h")
        #expect(a.count == 1)
        #expect(a[0].pattern == "/h/t/ansible-local-*")
        // Two of four project folders failing: /h/P/* would also skip the other two, with 10 files.
        let p = BackupNotes.group(["open /h/P/0/f0: permission denied", "open /h/P/1/f1: permission denied"], index: i, home: "/h")
        #expect(p.count == 2)
        #expect(BackupNotes.group(["open /h/t/ansible-local-1x/f: permission denied",
                                   "open /h/t/ansible-local-2y/f: permission denied"], home: "/h").count == 2)
    }

    @Test func unreadableFoldersCountAsUnknown() {
        let i = index(["/h/a/x/f", "/h/b/x/f"], unreadable: ["/h/b/x/secret"])
        let e = i.extra(of: "/h/*/x", besides: ["/h/a/x"])!
        #expect(e.unknown)
    }

    @Test func collectorReadsEscapedPaths() {
        #expect(FolderCollector.item(in: #"{"item":"/a/b\"c/d","x":1}"#) == "/a/b\"c/d")
        #expect(FolderCollector.item(in: #"{"item":"/a/b","x":1}"#) == "/a/b")
        #expect(FolderGlob.covers("/h/FP/*/w", "/h/FP/U1/w"))
        #expect(FolderGlob.covers("/h/FP", "/h/FP/U1/w"))
        #expect(!FolderGlob.covers("/h/FP/*/w", "/h/FP/U1/v"))
    }

    @Test func skipIsNarrowAndLiteral() {
        #expect(!BackupNotes.canSkip("/", home: "/Users/a"))
        #expect(!BackupNotes.canSkip("/Users", home: "/Users/a"))
        #expect(!BackupNotes.canSkip("/Users/a", home: "/Users/a"))
        #expect(BackupNotes.canSkip("/Users/a/.ansible/tmp", home: "/Users/a"))
        #expect(BackupNotes.escapedPattern("/x/[a]*?") == "/x/\\[a\\]\\*\\?")
    }
}

@Suite struct OpenWithTests {
    @Test func noValueOutsideAppBundle() {
        #expect(OpenWith.value(for: Bundle(for: BundleMarker.self)) == nil)
    }

    @Test func valueNamesTheApp() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("T-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let plist: [String: Any] = ["CFBundleIdentifier": "org.example.test", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let bundle = try #require(Bundle(url: app))
        let data = try #require(OpenWith.value(for: bundle))
        let dict = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(dict["bundleidentifier"] as? String == "org.example.test")
        #expect(dict["path"] as? String == app.path)
    }
}

private final class BundleMarker {}

@Suite struct ServerReachabilityTests {
    let fallback = ServerReachability.Target(host: "pi", port: 22, viaProxy: false)

    @Test func usesHostNameFromSSHConfig() {
        let out = "host pi\nhostname 10.0.1.3\nport 2222\nuser pi\nproxycommand none\n"
        let t = ServerReachability.parse(sshConfig: out, fallback: fallback)
        #expect(t == .init(host: "10.0.1.3", port: 2222, viaProxy: false))
    }

    @Test func detectsJumpHost() {
        let t = ServerReachability.parse(sshConfig: "hostname nas\nproxyjump bastion\n", fallback: fallback)
        #expect(t.viaProxy)
    }

    @Test func keepsFallbackOnEmptyOutput() {
        #expect(ServerReachability.parse(sshConfig: "", fallback: fallback) == fallback)
    }

    @Test func resolvesAliasThroughSSH() async {
        // Without a matching Host entry, ssh -G returns the name unchanged.
        let t = await ServerReachability.resolve(RemoteServer(host: "nl-test-no-such-alias", user: "u", port: 2201, path: "/x"))
        #expect(t.host == "nl-test-no-such-alias")
        #expect(t.port == 2201)
    }
}

@Test func remainingTimeFollowsTheSameKindOfBackup() {
    let start = Date(timeIntervalSince1970: 1000)
    var info = ProgressInfo()
    info.kind = .quick
    info.kindStarted = start
    #expect(info.remaining(now: start.addingTimeInterval(10)) == nil)
    info.expectedDuration = 300
    #expect(info.remaining(now: start.addingTimeInterval(100)) == 200)
    #expect(info.remaining(now: start.addingTimeInterval(400)) == nil)
}

@Suite struct SkippedRunTests {
    @Test func droppedConnectionsAreLost() {
        // Output from a check whose connection dropped.
        let dropped = ResticError(exitCode: 1, rawMessages: [
            "Fatal: config cannot be loaded: ssh command exited: exit status 255",
            "subprocess /usr/bin/ssh: client_loop: ssh_packet_write_poll: Connection to 10.0.1.3 port 22: Broken pipe",
            "Load(<config/0000000000>, 0, 0) returned error, retrying after 938.308727ms: Open /backups/x/config: connection lost",
        ])
        #expect(dropped.isConnectionLost)
        #expect(ResticError(exitCode: 1, rawMessages: ["Timeout, server pi not responding."]).isConnectionLost)
        #expect(ResticError(exitCode: 1, rawMessages: ["Connection to pi closed by remote host."]).isConnectionLost)
        #expect(ResticError(exitCode: 1, messages: ["the SFTP connection ended: ssh: Broken pipe"]).isConnectionLost)
        #expect(ResticError(exitCode: 1, messages: ["the SFTP server did not answer within 60 seconds"]).isConnectionLost)
    }

    @Test func faultsThatNeedTheUserAreNotLost() {
        #expect(!ResticError(exitCode: 1, rawMessages: ["me@h: Permission denied (publickey)."]).isConnectionLost)
        #expect(!ResticError(exitCode: 1, rawMessages: ["Host key verification failed."]).isConnectionLost)
        #expect(!ResticError(exitCode: 1, rawMessages: ["@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @"]).isConnectionLost)
        #expect(!ResticError(exitCode: 1, rawMessages: ["subsystem request failed on channel 0"]).isConnectionLost)
        #expect(!ResticError(exitCode: 1, rawMessages: ["kex_exchange_identification: Connection closed by remote host"]).isConnectionLost)
        #expect(!ResticError(exitCode: 1, rawMessages: ["Bad owner or permissions on /Users/me/.ssh/config"]).isConnectionLost)
        #expect(!ResticError(exitCode: 12).isConnectionLost)
    }

    @Test func unreachableServerIsLost() {
        #expect(BackupCoordinator.isConnectionLost(EngineError.serverUnreachable("pi", details: "ssh: connect to host pi port 22: Operation timed out")))
        #expect(BackupCoordinator.details(EngineError.serverUnreachable("pi", details: "timed out")) == "timed out")
        #expect(!BackupCoordinator.isConnectionLost(EngineError.serverRejectedKey("pi")))
    }

    private func record(_ outcome: BackupRecord.Outcome, disk: String = "A", repeats: Int? = nil) -> BackupRecord {
        var r = BackupRecord(diskID: disk, diskName: "pi", start: Date(timeIntervalSince1970: 0),
                             end: Date(timeIntervalSince1970: 1), outcome: outcome, trigger: .scheduled)
        r.repeats = repeats
        return r
    }

    @Test func skippedRecordsStayReadableForOlderVersions() throws {
        var r = record(.skipped, repeats: 4)
        r.details = "Broken pipe"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([r])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode([BackupRecord].self, from: data) == [r])

        // An older version knows only these outcomes and ignores keys it does not know.
        struct OldRecord: Decodable {
            enum Outcome: String, Decodable { case success, warning, failed, cancelled }
            var outcome: Outcome
            var messages: [String]
            var trigger: BackupTrigger
        }
        #expect(try decoder.decode([OldRecord].self, from: data).first?.outcome == .cancelled)

        // A real cancelled record stays cancelled.
        let cancelled = try encoder.encode([record(.cancelled)])
        #expect(try decoder.decode([BackupRecord].self, from: cancelled).first?.outcome == .cancelled)
    }

    @Test func skipsInARowAreCounted() {
        let history = [record(.skipped, repeats: 2), record(.skipped, disk: "B"), record(.skipped), record(.success), record(.skipped)]
        #expect(BackupCoordinator.skippedInARow(history, diskID: "A") == 3)
        #expect(BackupCoordinator.skippedInARow(history, diskID: "B") == 1)
        #expect(BackupCoordinator.skippedInARow([record(.failed), record(.skipped)], diskID: "A") == 0)
    }

    @Test func skippedRunsDoNotReplaceTheLastResult() {
        var failed = record(.failed)
        failed.messages = ["The server did not accept the Nine Lives key."]
        var skipped = record(.skipped)
        skipped.messages = ["pi stopped answering, so this backup was skipped."]
        let results = BackupCoordinator.currentResults(history: [skipped, failed], disks: ["A"], running: nil)
        #expect(results.map(\.outcome) == [.failed])
    }
}
