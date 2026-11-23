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

    @Test func samplerSpreadsOverStream() {
        let sampler = FileSampler(capacity: 8)
        for i in 0..<10_000 where sampler.shouldInspect() {
            sampler.keep(SampledFile(path: "f\(i)", size: Int64(i)))
        }
        let picks = sampler.result.map(\.size)
        #expect(picks.count >= 4 && picks.count <= 8)
        #expect(picks == picks.sorted())
        // Evenly spread: one pick in each eighth of the stream, give or take a block.
        #expect(picks.first! < 2_500)
        #expect(picks.last! > 7_500)
    }

    @Test func samplerRetriesWithinBlock() {
        let sampler = FileSampler(capacity: 4)
        var inspected = 0
        for i in 0..<3 where sampler.shouldInspect() {
            inspected += 1
            if i == 2 { sampler.keep(SampledFile(path: "f", size: 1)) }
        }
        // Stride is 1 while the buffer fills, so each item is its own block and only the last is kept.
        #expect(inspected == 3)
        #expect(sampler.result.count == 1)
    }

    @Test func samplesBackupFiles() async throws {
        let restic = try testRestic()
        let root = try makeTempDir()
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for i in 0..<20 { try "file \(i)".write(to: src.appendingPathComponent("f\(i)"), atomically: true, encoding: .utf8) }
        let repo = ResticRepo(url: root.appendingPathComponent("repo"), password: "pw")
        try await restic.initRepository(repo)
        let options = CreateOptions(sources: [src.path], excludePatterns: [], host: "test")
        let first = try await restic.backup(repo: repo, options: options, progress: { _ in })
        let second = try await restic.backup(repo: repo, options: options, progress: { _ in })
        for r in [first, second] {
            #expect(!r.sample.isEmpty)
            for f in r.sample {
                #expect(!f.path.hasPrefix("/"))
                let attrs = try FileManager.default.attributesOfItem(atPath: "/" + f.path)
                #expect(attrs[.size] as? Int64 == f.size)
            }
        }
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

    @Test func slashPatternsMarkersAndIncludesWork() async throws {
        let restic = try testRestic()
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
        try write("vms/a.pvm/disk")
        try write("vms/b.pvm/disk")
        let repo = ResticRepo(url: root.appendingPathComponent("repo"), password: "pw")
        try await restic.initRepository(repo)
        let r = try await restic.backup(
            repo: repo,
            options: CreateOptions(
                sources: [src.path],
                excludePatterns: ["Library/Application Support/*/Cache", ".nx/cache", "*.pvm"],
                includePatterns: [src.path + "/vms/a.pvm"],
                excludeIfPresent: ["pyvenv.cfg"]),
            progress: { _ in })
        let box = ItemBox()
        try await restic.listItems(repo: repo, snapshot: r.archiveID) { box.add($0) }
        let paths = box.items.map(\.path)
        #expect(paths.contains { $0.hasSuffix("Slack/settings.json") })
        #expect(paths.contains { $0.hasSuffix(".nx/project.json") })
        #expect(paths.contains { $0.hasSuffix("app/main.py") })
        #expect(!paths.contains { $0.hasSuffix("Slack/Cache/blob") })
        #expect(!paths.contains { $0.hasSuffix(".nx/cache/blob") })
        #expect(!paths.contains { $0.hasSuffix("env/lib/site.py") })
        #expect(paths.contains { $0.hasSuffix("a.pvm/disk") })
        #expect(!paths.contains { $0.hasSuffix("b.pvm/disk") })
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

/// Background processes run at scheduler priority 4. `ps` shows the priority of each pid.
@Suite(.serialized) struct ProcessPriorityTests {
    /// The script prints the priority of the shell and of a child it started later, then
    /// waits until the test has seen that line and prints both priorities again.
    private func priorities(background: Bool, raise: Bool) async throws -> [[Int]] {
        let go = try makeTempDir().appendingPathComponent("go")
        let script = """
            sleep 0.3; /bin/sleep 60 & K=$!; sleep 0.1
            ps -o pri= -p $$,$K | tr '\\n' ' '; echo
            while [ ! -f '\(go.path)' ]; do sleep 0.05; done
            ps -o pri= -p $$,$K | tr '\\n' ' '; echo
            kill $K
            """
        let priority = ProcessPriority(background: background)
        let lines = LockedLines()
        _ = try await ProcessPriority.$current.withValue(priority) {
            try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                environment: ["PATH": "/usr/bin:/bin"],
                onStdoutLine: { line in
                    lines.add(line)
                    if raise { priority.raise() }
                    FileManager.default.createFile(atPath: go.path, contents: nil)
                })
        }
        return lines.all.split(separator: "\n").map { $0.split(separator: " ").compactMap { Int($0) } }
    }

    @Test func backgroundReachesChildren() async throws {
        let p = try await priorities(background: true, raise: false)
        #expect(p == [[4, 4], [4, 4]])
    }

    @Test func raiseReachesRunningChildren() async throws {
        let p = try await priorities(background: true, raise: true)
        #expect(p.count == 2)
        #expect(p[0] == [4, 4])
        #expect(p[1].count == 2 && !p[1].contains(4))
    }

    @Test func normalPriorityIsNotBackground() async throws {
        let p = try await priorities(background: false, raise: false)
        #expect(p.count == 2)
        #expect(p.allSatisfy { $0.count == 2 && !$0.contains(4) })
    }
}
