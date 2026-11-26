import Foundation
import Testing
import ResticKit
@testable import NineLivesCore

@Suite struct ChangeTrackerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func state() -> IncrementalState {
        IncrementalState(
            snapshotID: "s1", eventID: 100, volumeUUIDs: ["/Users/me": "U"], configHash: "h",
            lastSweep: now.addingTimeInterval(-3600), lastForcedSweep: now.addingTimeInterval(-86_400),
            sweepSnapshotID: "s0", sweepErrors: [], fullDiskAccess: true, hardLinksChanged: false)
    }

    func facts(_ change: (inout ChangeFacts) -> Void = { _ in }) -> ChangeFacts {
        var h = ChangeHistory()
        h.folders = ["/Users/me/a", "/Users/me/b"]
        h.recursive = ["/Users/me/c"]
        var f = ChangeFacts(
            state: state(), newestSnapshotID: "s1", configHash: "h", volumeUUIDs: ["/Users/me": "U"], currentEventID: 200,
            sourcesInternal: true, history: h, fullDiskAccess: true, onMainsPower: true, now: now)
        change(&f)
        return f
    }

    func isFull(_ f: ChangeFacts) -> Bool {
        if case .full = ChangeTracker.decide(f) { return true }
        return false
    }

    @Test func incrementalWhenNothingIsOff() {
        #expect(ChangeTracker.decide(facts()) == .incremental([
            ChangedFolder(path: "/Users/me/a"), ChangedFolder(path: "/Users/me/b"), ChangedFolder(path: "/Users/me/c", recursive: true),
        ]))
    }

    @Test func eachRuleForcesAFullBackup() {
        #expect(isFull(facts { $0.state = nil }))
        #expect(isFull(facts { $0.newestSnapshotID = "other" }))
        #expect(isFull(facts { $0.newestSnapshotID = nil }))
        #expect(isFull(facts { $0.configHash = "changed" }))
        #expect(isFull(facts { $0.sourcesInternal = false }))
        #expect(isFull(facts { $0.volumeUUIDs = ["/Users/me": "V"] }))
        #expect(isFull(facts { $0.currentEventID = 50 }))
        #expect(isFull(facts { $0.state?.lastSweep = now.addingTimeInterval(-8 * 86_400) }))
        #expect(isFull(facts { $0.state?.lastSweep = now.addingTimeInterval(3600) }), "clock went back")
        #expect(isFull(facts { $0.state?.hardLinksChanged = true }))
        #expect(isFull(facts { $0.fullDiskAccess = false }))
        #expect(isFull(facts { $0.history = nil }))
        #expect(isFull(facts { $0.history?.completed = false }))
        #expect(isFull(facts { $0.history?.untrusted = "dropped" }))
        #expect(isFull(facts { $0.history?.overflow = true }))
        #expect(isFull(facts { f in f.history?.folders = Set((0...ChangeTracker.maxChangedFolders).map { "/Users/me/\($0)" }) }))
    }

    @Test func forcedSweepOnlyOnMainsPowerAndWhenDue() {
        #expect(ChangeTracker.decide(facts { $0.configHash = "x" }) == .full(reason: "the folders or skip rules changed", force: false))
        let due = facts { $0.configHash = "x"; $0.state?.lastForcedSweep = now.addingTimeInterval(-31 * 86_400) }
        #expect(ChangeTracker.decide(due) == .full(reason: "the folders or skip rules changed", force: true))
        var battery = due
        battery.onMainsPower = false
        #expect(ChangeTracker.decide(battery) == .full(reason: "the folders or skip rules changed", force: false))
        #expect(ChangeTracker.decide(facts { $0.state = nil }) == .full(reason: "no earlier backup with the engine", force: true))
    }

    @Test func configHashFollowsFilters() {
        let a = CreateOptions(sources: ["/b", "/a"], excludePatterns: ["x"])
        let b = CreateOptions(sources: ["/a", "/b"], excludePatterns: ["x"])
        let c = CreateOptions(sources: ["/a", "/b"], excludePatterns: ["y"])
        #expect(ChangeTracker.configHash(a) == ChangeTracker.configHash(b))
        #expect(ChangeTracker.configHash(a) != ChangeTracker.configHash(c))
    }

    @Test func canonicalPathOfDeletedFolder() throws {
        let dir = ChangeTracker.canonical(try tempDir().path)
        #expect(dir.hasPrefix("/private/"))
        #expect(ChangeTracker.canonical(dir + "/gone/deeper/") == dir + "/gone/deeper")
        #expect(ChangeTracker.canonical("/tmp") == "/private/tmp")
    }

    @Test func skipperDropsObviousNoise() {
        let s = PathSkipper(patterns: ["/Users/me/Library/Caches", "node_modules", ".nx/cache", "*.pyc"],
                            includes: ["/Users/me/p/node_modules"])
        #expect(s.skips("/Users/me/Library/Caches/x"))
        #expect(s.skips("/Users/me/q/node_modules/m"))
        #expect(s.skips("/Users/me/a/.nx/cache"))
        #expect(!s.skips("/Users/me/a/.nx/other"))
        #expect(!s.skips("/Users/me/p/node_modules/m"), "kept by the user")
        #expect(!s.skips("/Users/me/Library"))
    }

    @Test func spliceNotesRepeatOnlyWhatWasNotReadAgain() {
        let plain = ChangedFolder(path: "/u/a")
        #expect(BackupEngine.covers(plain, "/u/a"))
        #expect(BackupEngine.covers(plain, "/u/a/x"))
        #expect(!BackupEngine.covers(plain, "/u/a/x/y"))
        #expect(!BackupEngine.covers(plain, "/u/ab"))
        let deep = ChangedFolder(path: "/u/a", recursive: true)
        #expect(BackupEngine.covers(deep, "/u/a/x/y"))
        #expect(!BackupEngine.covers(deep, "/u/ab/x"))
    }

    @Test func pathChoicesAreEscaped() {
        var s = BackupSettings(rules: [])
        s.pathChoices = ["/Users/me/Photos [2020]": false, "/Users/me/Pro*jects": true]
        #expect(s.excludePatterns(home: "/Users/me").contains("/Users/me/Photos \\[2020\\]"))
        #expect(s.includePatterns == ["/Users/me/Pro\\*jects"])
        #expect(BackupSettings.escapePattern("a\\b?") == "a\\\\b\\?")
    }

    @Test func oldStateFilesStillLoad() throws {
        let json = #"{"id":"x","name":"X","mode":"repokey-blake2","diskEncrypted":false,"repoFolder":"f","addedAt":0}"#
        let disk = try JSONDecoder().decode(KnownDisk.self, from: Data(json.utf8))
        #expect(disk.incremental == nil)
        let record = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","diskID":"x","diskName":"X","start":0,"end":0,"outcome":"success","messages":[],"trigger":"manual"}"#
        #expect(try JSONDecoder().decode(BackupRecord.self, from: Data(record.utf8)).kind == nil)
    }

    @Test func historyReplayFindsAChangedFolder() async throws {
        let dir = URL(fileURLWithPath: ChangeTracker.canonical(try tempDir().path))
        let since = ChangeTracker.currentEventID
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("sub/file"))
        // FSEvents writes its history with a short delay.
        var found = false
        for _ in 0..<20 where !found {
            try await Task.sleep(for: .milliseconds(500))
            let h = await ChangeTracker.history(since: since, sources: [dir.path], timeout: 10)
            #expect(h.completed)
            found = h.folders.contains(dir.path + "/sub") || h.recursive.contains { dir.path.hasPrefix($0) || $0 == dir.path }
        }
        #expect(found)
    }
}
