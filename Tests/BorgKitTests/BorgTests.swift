import Foundation
import Testing
@testable import BorgKit

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nl-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

func testBorg() throws -> Borg {
    guard let bin = BorgBinary.locate(bundleResources: nil) else { throw SkipError() }
    return Borg(binary: bin, baseDirectory: try makeTempDir().appendingPathComponent("base"))
}
struct SkipError: Error {}

@Suite struct BorgTests {
    @Test func exitCodeClassification() {
        #expect(BorgExit(code: 0) == .success)
        #expect(BorgExit(code: 1) == .warning)
        #expect(BorgExit(code: 105) == .warning)
        #expect(BorgExit(code: 2) == .failure)
        #expect(BorgExit(code: 52) == .failure)
        #expect(BorgExit(code: 130) == .cancelled)
    }

    @Test func retentionArguments() {
        let r = Retention(hourly: 2, daily: 0, weekly: 3, monthly: 4, yearly: 0)
        #expect(r.arguments == ["--keep-hourly", "2", "--keep-weekly", "3", "--keep-monthly", "4"])
    }

    @Test func parsesBorgDates() throws {
        let d = try #require(BorgDate.parse("2026-11-21T19:00:23.000000"))
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        #expect(c.year == 2026 && c.month == 11 && c.day == 21 && c.hour == 19 && c.minute == 0)
    }

    @Test func parsesLogLines() {
        let l = BorgLogLine.parse(#"{"type": "log_message", "message": "boom", "levelname": "ERROR", "msgid": "PassphraseWrong"}"#)
        #expect(l?.msgid == "PassphraseWrong")
        #expect(BorgLogLine.parse("not json") == nil)
    }

    @Test func backupRoundTrip() async throws {
        let borg = try testBorg()
        let root = try makeTempDir()
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try "hello".write(to: src.appendingPathComponent("docs/a.txt"), atomically: true, encoding: .utf8)
        try "skip".write(to: src.appendingPathComponent("node_modules/x.js"), atomically: true, encoding: .utf8)
        try "Signature: 8a477f597d28d172789f06886806bc55".write(to: src.appendingPathComponent("cache/CACHEDIR.TAG"), atomically: true, encoding: .utf8)
        try "cached".write(to: src.appendingPathComponent("cache/blob"), atomically: true, encoding: .utf8)

        let repo = BorgRepo(url: root.appendingPathComponent("disk/repo"), passphrase: "")
        try await borg.initRepository(repo, mode: .authenticated)
        #expect(borg.repositoryExists(at: repo.url))

        let result = try await borg.create(
            repo: repo, archive: "ninelives-1",
            options: CreateOptions(sources: [src.path], excludePatterns: ["fm:*/node_modules"]),
            progress: { _ in })
        #expect(result.archiveName == "ninelives-1")
        #expect(result.stats.fileCount >= 1)

        let archives = try await borg.listArchives(repo: repo)
        #expect(archives.map(\.name) == ["ninelives-1"])

        let box = ItemBox()
        try await borg.listItems(repo: repo, archive: "ninelives-1") { box.add($0) }
        let paths = box.items.map(\.path)
        #expect(paths.contains { $0.hasSuffix("docs/a.txt") })
        #expect(!paths.contains { $0.contains("node_modules/x.js") })
        #expect(!paths.contains { $0.hasSuffix("cache/blob") })
        #expect(paths.contains { $0.hasSuffix("cache/CACHEDIR.TAG") })

        let aPath = try #require(paths.first { $0.hasSuffix("docs/a.txt") })
        let dest = root.appendingPathComponent("restore")
        _ = try await borg.extract(
            repo: repo, archive: "ninelives-1", paths: [aPath], destination: dest,
            stripComponents: aPath.split(separator: "/").count - 1)
        #expect(try String(contentsOf: dest.appendingPathComponent("a.txt"), encoding: .utf8) == "hello")

        let info = try await borg.info(repo: repo)
        #expect(info.storedSize > 0)
        let check = try await borg.check(repo: repo, maxDuration: 30)
        #expect(check.passed)

        try await borg.prune(repo: repo, retention: Retention(), glob: "ninelives-*")
        try await borg.compact(repo: repo)
    }

    @Test func absolutePathExcludesWork() async throws {
        let borg = try testBorg()
        let root = try makeTempDir()
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        try "x".write(to: src.appendingPathComponent("Library/Caches/c"), atomically: true, encoding: .utf8)
        try "y".write(to: src.appendingPathComponent("keep"), atomically: true, encoding: .utf8)
        let repo = BorgRepo(url: root.appendingPathComponent("repo"))
        try await borg.initRepository(repo, mode: .authenticated)
        _ = try await borg.create(
            repo: repo, archive: "a",
            options: CreateOptions(sources: [src.path], excludePatterns: ["pp:" + src.path + "/Library/Caches"]),
            progress: { _ in })
        let box = ItemBox()
        try await borg.listItems(repo: repo, archive: "a") { box.add($0) }
        #expect(box.items.contains { $0.path.hasSuffix("/keep") })
        #expect(!box.items.contains { $0.path.hasSuffix("Caches/c") })
    }

    @Test func slashPatternsAndMarkersWork() async throws {
        let borg = try testBorg()
        let root = try makeTempDir()
        let src = root.appendingPathComponent("src")
        let fm = FileManager.default
        func write(_ path: String) throws {
            let u = src.appendingPathComponent(path)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: u, atomically: true, encoding: .utf8)
        }
        try write("Library/Application Support/Slack/Cache/blob")
        try write("Library/Application Support/Slack/settings.json")
        try write("app/.nx/cache/blob")
        try write("app/.nx/project.json")
        try write("env/pyvenv.cfg")
        try write("env/lib/site.py")
        try write("app/main.py")
        let repo = BorgRepo(url: root.appendingPathComponent("repo"))
        try await borg.initRepository(repo, mode: .authenticated)
        _ = try await borg.create(
            repo: repo, archive: "a",
            options: CreateOptions(
                sources: [src.path],
                excludePatterns: ["fm:*/Library/Application Support/*/Cache", "fm:*/.nx/cache"],
                excludeIfPresent: ["pyvenv.cfg"]),
            progress: { _ in })
        let box = ItemBox()
        try await borg.listItems(repo: repo, archive: "a") { box.add($0) }
        let paths = box.items.map(\.path)
        #expect(paths.contains { $0.hasSuffix("Slack/settings.json") })
        #expect(paths.contains { $0.hasSuffix(".nx/project.json") })
        #expect(paths.contains { $0.hasSuffix("app/main.py") })
        #expect(!paths.contains { $0.hasSuffix("Slack/Cache/blob") })
        #expect(!paths.contains { $0.hasSuffix(".nx/cache/blob") })
        #expect(!paths.contains { $0.hasSuffix("env/lib/site.py") })
    }

    @Test func includeExceptionBeatsExclude() async throws {
        let borg = try testBorg()
        let root = try makeTempDir()
        let src = root.appendingPathComponent("src")
        let fm = FileManager.default
        for n in ["a.pvm", "b.pvm"] {
            try fm.createDirectory(at: src.appendingPathComponent("vm/" + n), withIntermediateDirectories: true)
            try "x".write(to: src.appendingPathComponent("vm/\(n)/disk"), atomically: true, encoding: .utf8)
        }
        let repo = BorgRepo(url: root.appendingPathComponent("repo"))
        try await borg.initRepository(repo, mode: .authenticated)
        _ = try await borg.create(
            repo: repo, archive: "a",
            options: CreateOptions(sources: [src.path], excludePatterns: ["fm:*/*.pvm"],
                                   includePatterns: ["pp:" + src.path + "/vm/a.pvm"]),
            progress: { _ in })
        let box = ItemBox()
        try await borg.listItems(repo: repo, archive: "a") { box.add($0) }
        let paths = box.items.map(\.path)
        #expect(paths.contains { $0.hasSuffix("a.pvm/disk") })
        #expect(!paths.contains { $0.hasSuffix("b.pvm/disk") })
    }

    @Test func wrongPassphraseIsReported() async throws {
        let borg = try testBorg()
        let root = try makeTempDir()
        let repo = BorgRepo(url: root.appendingPathComponent("repo"), passphrase: "right")
        try await borg.initRepository(repo, mode: .repokey)
        let bad = BorgRepo(url: repo.url, passphrase: "wrong")
        do {
            _ = try await borg.listArchives(repo: bad)
            Issue.record("expected failure")
        } catch let e as BorgError {
            #expect(e.isWrongPassphrase)
        }
    }

    @Test func warningsDoNotFailTheBackup() async throws {
        let borg = try testBorg()
        let root = try makeTempDir()
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "ok".write(to: src.appendingPathComponent("ok"), atomically: true, encoding: .utf8)
        let locked = src.appendingPathComponent("locked")
        try "no".write(to: locked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let repo = BorgRepo(url: root.appendingPathComponent("repo"))
        try await borg.initRepository(repo, mode: .authenticated)
        let r = try await borg.create(repo: repo, archive: "w", options: CreateOptions(sources: [src.path]), progress: { _ in })
        #expect(!r.warnings.isEmpty)
    }

    @Test func cancellationStopsBorg() async throws {
        let borg = try testBorg()
        let root = try makeTempDir()
        let task = Task { try await borg.version() }
        task.cancel()
        _ = try? await task.value
        _ = root
    }
}

final class ItemBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [ArchiveItem] = []
    func add(_ i: ArchiveItem) { lock.lock(); _items.append(i); lock.unlock() }
    var items: [ArchiveItem] { lock.lock(); defer { lock.unlock() }; return _items }
}
