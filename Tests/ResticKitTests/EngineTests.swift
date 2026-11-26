import Foundation
import Testing
@testable import ResticKit

@Suite struct EngineTests {
    let engine = Engine(binary: URL(fileURLWithPath: "/x/nl-engine"), cacheDirectory: URL(fileURLWithPath: "/c"),
                        ssh: SSHOptions(keyFile: URL(fileURLWithPath: "/k"), knownHostsFile: URL(fileURLWithPath: "/kh")))

    @Test func sweepArguments() {
        let o = CreateOptions(sources: ["/Users/me"], excludePatterns: ["*.log"], includePatterns: ["/Users/me/keep.log"],
                              host: "mac", tag: "ninelives")
        let a = engine.arguments(repo: ResticRepo(url: URL(fileURLWithPath: "/V/repo"), password: "p"), options: o,
                                 run: .sweep(parent: "abc", force: true), changesFile: nil)
        #expect(a == ["backup", "--parent", "abc", "--force", "--repo", "/V/repo", "--cache-dir", "/c", "--tag", "ninelives",
                      "--host", "mac", "--exclude-caches", "--one-file-system", "--exclude-if-present", ".nobackup",
                      "--exclude", "*.log", "--exclude", "!/Users/me/keep.log", "--", "/Users/me"])
    }

    @Test func spliceArgumentsOverSFTP() throws {
        let remote = SFTPLocation(host: "nas", port: 2222, user: "me", path: "backups/mac")
        let a = engine.arguments(repo: ResticRepo(remote: remote, password: "p"), options: CreateOptions(sources: ["/a"]),
                                 run: .splice(parent: "abc", changes: []), changesFile: URL(fileURLWithPath: "/t/changes"))
        #expect(Array(a.prefix(7)) == ["splice", "--parent", "abc", "--changed", "/t/changes", "--repo", "backups/mac"])
        let i = try #require(a.firstIndex(of: "--ssh-json"))
        let argv = try JSONSerialization.jsonObject(with: Data(a[i + 1].utf8)) as? [String]
        #expect(argv?.first == "/usr/bin/ssh")
        #expect(argv?.suffix(5) == ["-p", "2222", "me@nas", "-s", "sftp"])
        #expect(!a.contains("p"), "the password is passed in the environment")
    }

    @Test func changesFile() {
        #expect(Engine.changesText([ChangedFolder(path: "/a b"), ChangedFolder(path: "/c", recursive: true)]) == "/a b\nR /c\n")
    }

    @Test func parsesOutput() {
        let progress = LockedLines()
        let out = EngineOutput(folders: FolderCollector(), progress: { progress.add($0.currentPath) })
        out.line(#"{"type":"progress","files":3,"bytes":10,"path":"/a/x"}"#)
        out.line(#"{"items":2,"path":"/a","type":"folder"}"#)
        out.line(#"{"items":1,"path":"/a/b","type":"folder"}"#)
        out.line(#"{"message":"Permission denied","path":"/a/locked","type":"error"}"#)
        out.line(#"{"message":"parent not used","type":"warning"}"#)
        out.line("not json")
        out.line(#"{"type":"summary","snapshot_id":"0123abcd","parent":null,"kind":"backup","files":5,"bytes":99,"files_new":1,"files_changed":2,"data_added":7,"data_added_packed":6,"duration":1.5,"hard_links_changed":true,"sample":[{"path":"/a/x","size":1}]}"#)
        #expect(progress.all == "/a/x")
        #expect(out.errors == [EngineItemError(path: "/a/locked", message: "Permission denied")])
        #expect(out.errors[0].resticStyle == "read /a/locked: permission denied")
        #expect(out.warnings == ["parent not used"])
        #expect(out.summary?.snapshot_id == "0123abcd")
        #expect(out.summary?.hard_links_changed == true)
        let f = try! #require(out.folders)
        let a = f.parent.indices.first { f.names[Int(f.name[$0])] == "a" && f.parent[$0] == 0 }
        #expect(a.map { f.items[$0] } == 2)
        let locked = f.parent.indices.first { f.names[Int(f.name[$0])] == "locked" }
        #expect(locked.map { f.unknown[$0] } == true)
    }

    /// Runs the real engine when it has been built, against a local repository made with restic.
    @Test func endToEndWithBuiltEngine() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bin = root.appendingPathComponent("Engine/target/release/nl-engine")
        guard FileManager.default.isExecutableFile(atPath: bin.path),
              let resticBin = ResticBinary.locate(bundleResources: nil) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nl-engine-swift-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("a"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: src.appendingPathComponent("a/f"))
        let repo = ResticRepo(url: dir.appendingPathComponent("repo"), password: "pw")
        let restic = Restic(binary: resticBin)
        try await restic.initRepository(repo)
        let e = Engine(binary: bin)
        let opts = CreateOptions(sources: [src.path], host: "h")
        let full = try await e.backup(repo: repo, options: opts, run: .sweep(parent: nil, force: false)) { _ in }
        #expect(full.create.stats.fileCount == 1)
        #expect(full.create.folders != nil)
        #expect(full.create.archiveID.count == 64)
        try Data("changed".utf8).write(to: src.appendingPathComponent("a/f"))
        let quick = try await e.backup(
            repo: repo, options: opts, run: .splice(parent: full.create.archiveID, changes: [ChangedFolder(path: src.path + "/a")])) { _ in }
        #expect(quick.filesChanged == 1)
        #expect(quick.create.folders == nil)
        #expect(try await restic.listArchives(repo: repo).first?.id == quick.create.archiveID)
        await #expect(throws: ResticError.self) {
            _ = try await Engine(binary: bin).backup(repo: ResticRepo(url: repo.url, password: "wrong"), options: opts,
                                                     run: .sweep(parent: nil, force: false)) { _ in }
        }
    }
}
