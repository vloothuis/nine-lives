import Foundation
import Testing
import ResticKit
@testable import NineLivesCore

/// Full and quick backups through `BackupEngine` with the tools from a built app, onto a mounted disk
/// image, then a restore with restic that must match the source.
///
/// Runs only when NL_E2E_VOLUME is the mount point of a writable disk image and NL_E2E_APP is a
/// built `Nine Lives.app`. See scripts/e2e.sh.
@Suite(.serialized) struct EndToEndTests {
    struct Setup {
        let root: URL, home: URL, volume: VolumeInfo, engine: BackupEngine, restic: URL
    }

    static func setup() throws -> Setup? {
        let env = ProcessInfo.processInfo.environment
        guard let mount = env["NL_E2E_VOLUME"], let app = env["NL_E2E_APP"] else { return nil }
        let resources = URL(fileURLWithPath: app).appendingPathComponent("Contents/Resources")
        let resticBin = resources.appendingPathComponent("restic")
        let engineBin = resources.appendingPathComponent("nl-engine")
        let root = URL(fileURLWithPath: ChangeTracker.canonical(try tempDir().path))
        let target = URL(fileURLWithPath: mount).appendingPathComponent("run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let engine = BackupEngine(
            restic: Restic(binary: resticBin, cacheDirectory: root.appendingPathComponent("cache")),
            engine: Engine(binary: engineBin, cacheDirectory: root.appendingPathComponent("cache/nl-engine")),
            secrets: MemorySecretStore(),
            catalogs: CatalogStore(directory: root.appendingPathComponent("catalogs")))
        return Setup(root: root, home: root.appendingPathComponent("home"), volume: fakeVolume(at: target, encrypted: false),
                     engine: engine, restic: resticBin)
    }

    func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func makeTree(_ home: URL) throws {
        for d in 0..<20 {
            for f in 0..<50 {
                try write(home.appendingPathComponent("Documents/project \(d)/src/file\(f).txt"), "project \(d) file \(f)\n")
            }
        }
        try write(home.appendingPathComponent("Photos/café/ünïcode.jpg"), String(repeating: "x", count: 200_000))
        try write(home.appendingPathComponent("Library/Caches/app/blob"), "cache")
        try write(home.appendingPathComponent("Skipped/.nobackup"), "")
        try write(home.appendingPathComponent("Skipped/secret"), "not backed up")
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent("Documents/link").path,
                                                   withDestinationPath: "project 1/src/file1.txt")
    }

    /// Changes of the kinds people make every day, done right before the backup starts.
    func change(_ home: URL, round: Int) throws {
        try write(home.appendingPathComponent("Documents/project 3/src/file7.txt"), "changed in round \(round)\n")
        try write(home.appendingPathComponent("Documents/project 4/new \(round).txt"), "new in round \(round)\n")
        try FileManager.default.removeItem(at: home.appendingPathComponent("Documents/project \(5 + round)/src/file9.txt"))
        try FileManager.default.moveItem(at: home.appendingPathComponent("Documents/project \(10 + round)"),
                                         to: home.appendingPathComponent("Documents/renamed \(round)"))
        try write(home.appendingPathComponent("Documents/deep \(round)/a/b/c/file.txt"), "deep \(round)\n")
        try FileManager.default.removeItem(at: home.appendingPathComponent("Documents/project \(15 + round)"))
        try write(home.appendingPathComponent("Skipped/later"), "still not backed up")
    }

    func run(_ args: [String], env: [String: String] = [:]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Restores the newest snapshot with restic and compares it with the source.
    func restoreMatches(_ s: Setup, disk: KnownDisk, label: String) throws {
        let repo = try s.engine.repo(for: disk, on: s.volume)
        let env = ["RESTIC_PASSWORD": repo.password]
        let out = s.root.appendingPathComponent("restore-\(label)")
        let (rc, text) = try run([s.restic.path, "-r", repo.url.path, "restore", "latest", "--target", out.path, "-q"], env: env)
        #expect(rc == 0, "restore \(label): \(text)")
        let restored = out.appendingPathComponent(String(s.home.path.dropFirst()))
        let (drc, diff) = try run(["/usr/bin/diff", "-r", "-x", "Caches", "-x", "Skipped", s.home.path, restored.path])
        #expect(drc == 0, "restored copy differs after \(label):\n\(diff.prefix(2000))")
        #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent("Library/Caches").path))
        // Like restic, a folder with a .nobackup marker keeps only the marker.
        let skipped = (try? FileManager.default.contentsOfDirectory(atPath: restored.appendingPathComponent("Skipped").path)) ?? []
        #expect(skipped == [".nobackup"], "restored from a .nobackup folder: \(skipped)")
        let (crc, check) = try run([s.restic.path, "-r", repo.url.path, "check", "--read-data", "-q"], env: env)
        #expect(crc == 0, "check after \(label): \(check)")
    }

    @Test func fullThenQuickBackupsRestoreCorrectly() async throws {
        guard let s = try Self.setup() else { return }
        let saved = BackupEngine.fullDiskAccess
        BackupEngine.fullDiskAccess = { true }
        defer { BackupEngine.fullDiskAccess = saved }
        try makeTree(s.home)

        var disk = try await s.engine.createDisk(on: s.volume, passphrase: "e2e pass")
        var settings = BackupSettings(sources: [s.home.path])
        settings.rules = DefaultRules.all
        settings.rules.append(ExcludeRule(id: "t", title: "t", detail: "", kind: .absolute,
                                          value: s.home.path + "/Library/Caches", builtIn: false))

        func backup(_ label: String) async throws -> BackupRunResult {
            let r = try await s.engine.runBackup(disk: disk, on: s.volume, settings: settings, progress: { _ in })
            disk = r.disk
            disk.incremental = r.incremental
            print("e2e \(label): \(r.kind) files \(r.create.stats.fileCount)")
            return r
        }

        let first = try await backup("first")
        #expect(first.kind == .full)
        try restoreMatches(s, disk: disk, label: "first")

        for round in 1...3 {
            try change(s.home, round: round)
            let r = try await backup("round \(round)")
            #expect(r.kind == .quick, "round \(round) should be a quick backup")
            try restoreMatches(s, disk: disk, label: "round \(round)")
        }

        let before = disk.incremental?.snapshotID
        let idle = try await backup("no changes")
        #expect(idle.kind == .quick)
        #expect(idle.create.stats.deduplicatedSize < 10_000, "a backup without changes adds almost nothing")
        #expect(idle.create.archiveID != before)

        // A change to the skip rules makes the next backup a full one, which must agree with the quick ones.
        settings.rules.append(ExcludeRule(id: "u", title: "u", detail: "", kind: .absolute,
                                          value: s.home.path + "/Documents/project 0", builtIn: false))
        let full = try await backup("rules changed")
        #expect(full.kind == .full)
        let repo = try s.engine.repo(for: disk, on: s.volume)
        let (_, ls) = try run([s.restic.path, "-r", repo.url.path, "ls", "latest", "-q"], env: ["RESTIC_PASSWORD": repo.password])
        #expect(!ls.contains("/Documents/project 0/"))
        #expect(ls.contains("/Documents/renamed 3/"))
    }
}
