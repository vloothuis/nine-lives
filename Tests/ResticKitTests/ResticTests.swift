import Foundation
import Testing
@testable import ResticKit

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nl-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

func testRestic() throws -> Restic {
    guard let bin = ResticBinary.locate(bundleResources: nil) else { throw SkipError() }
    return Restic(binary: bin, cacheDirectory: try makeTempDir().appendingPathComponent("cache"))
}
struct SkipError: Error {}

@Suite struct ResticTests {
    @Test func exitCodeClassification() {
        #expect(ResticExit(code: 0) == .success)
        #expect(ResticExit(code: 3) == .warning)
        #expect(ResticExit(code: 1) == .failure)
        #expect(ResticExit(code: 12) == .failure)
        #expect(ResticExit(code: 130) == .cancelled)
    }

    @Test func retentionArguments() {
        let r = Retention(hourly: 2, daily: 0, weekly: 3, monthly: 4, yearly: 0)
        #expect(r.arguments == ["--keep-hourly", "2", "--keep-weekly", "3", "--keep-monthly", "4"])
    }

    @Test func parsesResticDates() throws {
        let d = try #require(ResticDate.parse("2026-11-21T19:00:23.123456789+01:00"))
        let utc = try #require(ResticDate.parse("2026-11-21T18:00:23Z"))
        #expect(abs(d.timeIntervalSince(utc) - 0.123456789) < 0.001)
    }

    @Test func parsesMessages() {
        let m = ResticMessage.parse(#"{"message_type":"exit_error","code":12,"message":"Fatal: wrong password or no key found"}"#)
        #expect(m?.code == 12)
        #expect(ResticMessage.parse("not json") == nil)
    }

    @Test func sftpLocations() {
        #expect(SFTPLocation(host: "nas", port: 22, user: "me", path: "backups/mac").repository == "sftp:me@nas:backups/mac")
        #expect(SFTPLocation(host: "::1", port: 22, user: "u", path: "/srv").repository == "sftp:u@[::1]:/srv")
        let ssh = SSHOptions(keyFile: URL(fileURLWithPath: "/a b/key"), knownHostsFile: URL(fileURLWithPath: "/k"))
        let cmd = ssh.sftpCommand(SFTPLocation(host: "nas", port: 2222, user: "me", path: "x"))
        #expect(cmd.contains("'/a b/key'"))
        #expect(cmd.hasSuffix("'-p' '2222' 'me@nas' '-s' 'sftp'"))
    }

    @Test func backupRoundTrip() async throws {
        let restic = try testRestic()
        let root = try makeTempDir()
        let src = root.appendingPathComponent("src")
        let fm = FileManager.default
        try fm.createDirectory(at: src.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: src.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try fm.createDirectory(at: src.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try "hello".write(to: src.appendingPathComponent("docs/a.txt"), atomically: true, encoding: .utf8)
        try "skip".write(to: src.appendingPathComponent("node_modules/x.js"), atomically: true, encoding: .utf8)
        try "Signature: 8a477f597d28d172789f06886806bc55".write(to: src.appendingPathComponent("cache/CACHEDIR.TAG"), atomically: true, encoding: .utf8)
        try "cached".write(to: src.appendingPathComponent("cache/blob"), atomically: true, encoding: .utf8)

        let repo = ResticRepo(url: root.appendingPathComponent("disk/repo"), password: "pw")
        let id = try await restic.initRepository(repo)
        #expect(!id.isEmpty)
        #expect(restic.repositoryExists(at: repo.url))
        #expect(try await restic.repositoryID(repo: repo) == id)

        let result = try await restic.backup(
            repo: repo, options: CreateOptions(sources: [src.path], excludePatterns: ["node_modules"], host: "test"),
            progress: { _ in })
        #expect(result.stats.fileCount >= 1)

        let archives = try await restic.listArchives(repo: repo, tag: "ninelives")
        #expect(archives.map(\.id) == [result.archiveID])

        let box = ItemBox()
        try await restic.listItems(repo: repo, snapshot: result.archiveID) { box.add($0) }
        let paths = box.items.map(\.path)
        #expect(!paths.contains { $0.hasPrefix("/") })
        #expect(paths.contains { $0.hasSuffix("docs/a.txt") })
        #expect(!paths.contains { $0.contains("node_modules/x.js") })
        #expect(!paths.contains { $0.hasSuffix("cache/blob") })

        let aPath = try #require(paths.first { $0.hasSuffix("docs/a.txt") })
        let dest = root.appendingPathComponent("restore")
        _ = try await restic.restore(repo: repo, snapshot: result.archiveID, paths: [aPath], destination: dest)
        #expect(try String(contentsOf: dest.appendingPathComponent(aPath), encoding: .utf8) == "hello")

        #expect(try await restic.storedSize(repo: repo) > 0)
        #expect(try await restic.check(repo: repo, readDataSubset: "10%").passed)
        try await restic.forget(repo: repo, retention: Retention(), tag: "ninelives")
        try await restic.unlock(repo: repo)
    }

    @Test func absolutePathExcludesWork() async throws {
        let restic = try testRestic()
        let root = try makeTempDir()
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        try "x".write(to: src.appendingPathComponent("Library/Caches/c"), atomically: true, encoding: .utf8)
        try "y".write(to: src.appendingPathComponent("keep"), atomically: true, encoding: .utf8)
        let repo = ResticRepo(url: root.appendingPathComponent("repo"), password: "pw")
        try await restic.initRepository(repo)
        let r = try await restic.backup(
            repo: repo,
            options: CreateOptions(sources: [src.path], excludePatterns: [src.path + "/Library/Caches"]),
            progress: { _ in })
        let box = ItemBox()
        try await restic.listItems(repo: repo, snapshot: r.archiveID) { box.add($0) }
        #expect(box.items.contains { $0.path.hasSuffix("/keep") })
        #expect(!box.items.contains { $0.path.hasSuffix("Caches/c") })
    }

    @Test func wrongPassphraseIsReported() async throws {
        let restic = try testRestic()
        let root = try makeTempDir()
        let repo = ResticRepo(url: root.appendingPathComponent("repo"), password: "right")
        try await restic.initRepository(repo)
        do {
            _ = try await restic.listArchives(repo: ResticRepo(url: repo.url, password: "wrong"))
            Issue.record("expected failure")
        } catch let e as ResticError {
            #expect(e.isWrongPassphrase)
        }
        do {
            _ = try await restic.repositoryID(repo: ResticRepo(url: root.appendingPathComponent("nope"), password: "x"))
            Issue.record("expected failure")
        } catch let e as ResticError {
            #expect(e.isRepositoryMissing)
        }
    }

    @Test func warningsDoNotFailTheBackup() async throws {
        let restic = try testRestic()
        let root = try makeTempDir()
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "ok".write(to: src.appendingPathComponent("ok"), atomically: true, encoding: .utf8)
        let locked = src.appendingPathComponent("locked")
        try "no".write(to: locked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let repo = ResticRepo(url: root.appendingPathComponent("repo"), password: "pw")
        try await restic.initRepository(repo)
        let r = try await restic.backup(repo: repo, options: CreateOptions(sources: [src.path]), progress: { _ in })
        #expect(!r.warnings.isEmpty)
    }

    @Test func cancellationStopsRestic() async throws {
        let restic = try testRestic()
        let task = Task { try await restic.version() }
        task.cancel()
        _ = try? await task.value
    }
}

final class ItemBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [ArchiveItem] = []
    func add(_ i: ArchiveItem) { lock.lock(); _items.append(i); lock.unlock() }
    var items: [ArchiveItem] { lock.lock(); defer { lock.unlock() }; return _items }
}
