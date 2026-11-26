import Foundation
import Testing
import ResticKit
@testable import NineLivesCore

/// A small seeded generator, so a failing case can be repeated from its seed.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Property tests for the rules that decide what a quick backup reads again.
@Suite struct ChangeTrackerPropertyTests {
    static let parts = ["a", "b", "ab", "a b", "café", "node_modules", "Caches", ".nx", "cache", "x.log"]

    func path(_ g: inout SplitMix, maxDepth: Int = 5) -> String {
        let n = Int.random(in: 1...maxDepth, using: &g)
        return "/" + (0..<n).map { _ in Self.parts.randomElement(using: &g)! }.joined(separator: "/")
    }

    func pattern(_ g: inout SplitMix) -> String {
        let n = Int.random(in: 1...2, using: &g)
        let p = (0..<n).map { _ in Self.parts.randomElement(using: &g)! }.joined(separator: "/")
        return Bool.random(using: &g) ? "/" + p : p
    }

    /// Any single failed check makes the decision a full backup, and with none failed it is a quick one.
    @Test func anyFailedCheckMeansAFullBackup() {
        let base = ChangeTrackerTests()
        let now = base.now
        let breakers: [(inout ChangeFacts) -> Void] = [
            { $0.state = nil }, { $0.newestSnapshotID = "other" }, { $0.configHash = "changed" },
            { $0.sourcesInternal = false }, { $0.volumeUUIDs = ["/Users/me": "V"] }, { $0.currentEventID = 50 },
            { $0.state?.lastSweep = now.addingTimeInterval(-8 * 86_400) }, { $0.state?.hardLinksChanged = true },
            { $0.fullDiskAccess = false }, { $0.history = nil }, { $0.history?.completed = false },
            { $0.history?.untrusted = "dropped" }, { $0.history?.overflow = true },
        ]
        var g = SplitMix(state: 1)
        for _ in 0..<500 {
            let chosen = breakers.indices.filter { _ in Int.random(in: 0..<4, using: &g) == 0 }
            let f = base.facts { f in for i in chosen { breakers[i](&f) } }
            let full: Bool
            if case .full = ChangeTracker.decide(f) { full = true } else { full = false }
            #expect(full == !chosen.isEmpty, "checks broken: \(chosen)")
        }
    }

    /// The skipper never skips the way to a kept path or anything inside it, and what it skips,
    /// it skips below too.
    @Test func skipperKeepsIncludesAndIsClosedDownwards() {
        var g = SplitMix(state: 2)
        for _ in 0..<2000 {
            let patterns = (0..<Int.random(in: 1...4, using: &g)).map { _ in pattern(&g) }
            let includes = (0..<Int.random(in: 0...2, using: &g)).map { _ in path(&g) }
            let s = PathSkipper(patterns: patterns, includes: includes)
            let p = path(&g)
            let child = p + "/" + Self.parts.randomElement(using: &g)!
            for i in includes where ChangeTracker.isInside(p, i) || ChangeTracker.isInside(i, p) {
                #expect(!s.skips(p), "\(p) is kept by \(i), patterns \(patterns)")
            }
            if s.skips(p) {
                #expect(s.skips(child), "\(p) is skipped but \(child) is not, patterns \(patterns), includes \(includes)")
            }
        }
    }

    /// The skipper skips a path only when restic's own matcher excludes it. Otherwise a quick backup
    /// would miss changes in a folder that a full backup keeps. The cases come from restic 0.18.1.
    @Test func skipperNeverSkipsWhatResticKeeps() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Engine/tests/data/restic_filter_cases.tsv"), encoding: .utf8)
        var checked = 0, skipped = 0
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, f[0] == "M", f[3] != "err" else { continue }
            if PathSkipper(patterns: [f[1]]).skips(f[2]) {
                #expect(f[3] == "true", "skips \(f[2]) for pattern \(f[1]), restic does not")
                skipped += 1
            }
            checked += 1
        }
        #expect(checked > 1000)
        #expect(skipped >= 10, "only \(skipped) cases are skipped, so the check says little")
    }

    /// `covers` agrees with a plain definition: a changed folder covers itself and its items, and a
    /// recursive one covers everything below it.
    @Test func coversMatchesItsDefinition() {
        var g = SplitMix(state: 3)
        for _ in 0..<5000 {
            let c = ChangedFolder(path: path(&g, maxDepth: 3), recursive: Bool.random(using: &g))
            let p = path(&g)
            let parts = p.split(separator: "/"), cparts = c.path.split(separator: "/")
            let below = parts.count >= cparts.count && Array(parts.prefix(cparts.count)) == cparts
            let expected = c.recursive ? below : below && parts.count <= cparts.count + 1
            #expect(BackupEngine.covers(c, p) == expected, "\(c) and \(p)")
        }
    }

    /// Canonical paths are stable: making one canonical again changes nothing.
    @Test func canonicalIsIdempotent() throws {
        let dir = try tempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("l"), withDestinationURL: dir.appendingPathComponent("a"))
        var g = SplitMix(state: 4)
        let names = ["a", "b", "l", "gone", "."]
        for _ in 0..<500 {
            let p = dir.path + "/" + (0..<Int.random(in: 1...4, using: &g)).map { _ in names.randomElement(using: &g)! }.joined(separator: "/")
            let c = ChangeTracker.canonical(p)
            #expect(ChangeTracker.canonical(c) == c, "\(p)")
            #expect(c.hasPrefix("/private/"))
        }
    }
}
