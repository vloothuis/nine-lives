import CoreServices
import CryptoKit
import Foundation
import ResticKit

/// What Nine Lives remembers after a backup to decide whether the next one can be incremental.
public struct IncrementalState: Codable, Equatable, Sendable {
    /// The snapshot the backup made.
    public var snapshotID: String
    /// The FSEvents ID taken just before the backup began.
    public var eventID: UInt64
    /// The FSEvents UUID of the volume of each source.
    public var volumeUUIDs: [String: String]
    /// Hash of the sources and filters.
    public var configHash: String
    public var lastSweep: Date
    public var lastForcedSweep: Date?
    /// The snapshot of the last sweep, whose folder index stays valid for snapshots spliced from it.
    public var sweepSnapshotID: String
    /// Items the last sweep could not read, in restic's message form. A splice does not look at them
    /// again unless they are in a folder it reads, so its notes repeat them.
    public var sweepErrors: [EngineItemError]
    public var fullDiskAccess: Bool
    /// The last splice changed a hard-linked file, so other links may be stale until a sweep.
    public var hardLinksChanged: Bool

    public init(snapshotID: String, eventID: UInt64, volumeUUIDs: [String: String], configHash: String, lastSweep: Date,
                lastForcedSweep: Date?, sweepSnapshotID: String, sweepErrors: [EngineItemError], fullDiskAccess: Bool,
                hardLinksChanged: Bool) {
        self.snapshotID = snapshotID
        self.eventID = eventID
        self.volumeUUIDs = volumeUUIDs
        self.configHash = configHash
        self.lastSweep = lastSweep
        self.lastForcedSweep = lastForcedSweep
        self.sweepSnapshotID = sweepSnapshotID
        self.sweepErrors = sweepErrors
        self.fullDiskAccess = fullDiskAccess
        self.hardLinksChanged = hardLinksChanged
    }
}

/// FSEvents since an event ID, reduced to changed folders.
public struct ChangeHistory: Equatable, Sendable {
    /// Folders with changes, canonical, without a trailing slash.
    public var folders: Set<String> = []
    /// Folders below which FSEvents lost detail, so everything in them must be read.
    public var recursive: Set<String> = []
    /// Set when an event says the history cannot be trusted, with the reason.
    public var untrusted: String?
    /// More folders changed than are worth a splice.
    public var overflow = false
    public var completed = true

    public init() {}
}

public enum BackupDecision: Equatable, Sendable {
    case full(reason: String, force: Bool)
    case incremental([ChangedFolder])
}

/// The facts the decision is made from, gathered just before a backup.
public struct ChangeFacts: Sendable {
    public var state: IncrementalState?
    /// The newest snapshot with Nine Lives' tag in the repository.
    public var newestSnapshotID: String?
    public var configHash: String
    public var volumeUUIDs: [String: String]
    public var currentEventID: UInt64
    /// Every source is on the internal startup volume.
    public var sourcesInternal: Bool
    public var history: ChangeHistory?
    public var fullDiskAccess: Bool
    public var onMainsPower: Bool
    public var now: Date

    public init(state: IncrementalState?, newestSnapshotID: String?, configHash: String, volumeUUIDs: [String: String],
                currentEventID: UInt64, sourcesInternal: Bool, history: ChangeHistory?, fullDiskAccess: Bool,
                onMainsPower: Bool, now: Date) {
        self.state = state
        self.newestSnapshotID = newestSnapshotID
        self.configHash = configHash
        self.volumeUUIDs = volumeUUIDs
        self.currentEventID = currentEventID
        self.sourcesInternal = sourcesInternal
        self.history = history
        self.fullDiskAccess = fullDiskAccess
        self.onMainsPower = onMainsPower
        self.now = now
    }
}

public enum ChangeTracker {
    public static let maxChangedFolders = 50_000
    public static let sweepEvery: TimeInterval = 7 * 24 * 3600
    public static let forceEvery: TimeInterval = 30 * 24 * 3600

    /// Chooses between a splice of the changed folders and a full sweep. Pure, so it can be tested.
    public static func decide(_ f: ChangeFacts) -> BackupDecision {
        if let d = precheck(f) { return d }
        let h = f.history
        guard let h, h.completed else { return full(f, "the file change history could not be read") }
        if let why = h.untrusted { return full(f, why) }
        guard !h.overflow, h.folders.count + h.recursive.count <= maxChangedFolders else {
            return full(f, "more than \(maxChangedFolders.formatted()) folders changed")
        }
        let recursive = h.recursive.map { ChangedFolder(path: $0, recursive: true) }
        let plain = h.folders.subtracting(h.recursive).map { ChangedFolder(path: $0) }
        return .incremental((recursive + plain).sorted { $0.path < $1.path })
    }

    /// The checks that need no FSEvents history. Returns nil when the history decides.
    public static func precheck(_ f: ChangeFacts) -> BackupDecision? {
        guard let s = f.state else { return full(f, "no earlier backup with the engine") }
        guard f.newestSnapshotID == s.snapshotID else { return full(f, "the newest backup is not the one Nine Lives made last") }
        guard s.configHash == f.configHash else { return full(f, "the folders or skip rules changed") }
        guard f.sourcesInternal else { return full(f, "a folder to back up is not on the internal disk") }
        guard s.volumeUUIDs == f.volumeUUIDs else { return full(f, "the disk of a folder to back up changed") }
        guard f.currentEventID >= s.eventID else { return full(f, "the file change history was reset") }
        guard f.now.timeIntervalSince(s.lastSweep) <= sweepEvery, f.now >= s.lastSweep else {
            return full(f, "the last full backup is more than 7 days old")
        }
        guard !s.hardLinksChanged else { return full(f, "a file with several hard links changed") }
        guard s.fullDiskAccess == f.fullDiskAccess else { return full(f, "Full Disk Access changed") }
        return nil
    }

    /// A full sweep reads all file content again when the last such sweep is old and the Mac is on mains power.
    static func full(_ f: ChangeFacts, _ reason: String) -> BackupDecision {
        let due = f.state?.lastForcedSweep.map { f.now.timeIntervalSince($0) > forceEvery } ?? true
        return .full(reason: reason, force: f.onMainsPower && due)
    }

    /// A hash of everything that decides what a backup contains.
    public static func configHash(_ o: CreateOptions) -> String {
        var parts = ["v1"] + o.sources.sorted()
        parts += ["--"] + o.excludePatterns + ["--"] + o.includePatterns + ["--"] + o.excludeIfPresent
        // Left out when empty, so hashes from before this option stay the same.
        if !o.excludeGitignored.isEmpty { parts += ["--gitignored"] + o.excludeGitignored }
        parts += [o.excludeCaches ? "caches" : "", o.oneFileSystem ? "onefs" : "", o.host ?? "", o.tag]
        let data = Data(parts.joined(separator: "\u{1f}").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Facts about the sources

    /// The FSEvents UUID of each source's volume, and whether all are on the internal startup volume.
    public static func volumes(of sources: [String]) -> (uuids: [String: String], onInternal: Bool) {
        var root = stat()
        guard stat("/", &root) == 0 else { return ([:], false) }
        var uuids: [String: String] = [:]
        var onInternal = true
        for s in sources {
            var st = stat()
            guard stat(s, &st) == 0 else { onInternal = false; continue }
            if st.st_dev != root.st_dev { onInternal = false }
            if let u = FSEventsCopyUUIDForDevice(st.st_dev) {
                uuids[s] = CFUUIDCreateString(nil, u) as String
            } else {
                onInternal = false
            }
        }
        let rootInternal = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal ?? false
        return (uuids, onInternal && rootInternal)
    }

    public static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    // MARK: - FSEvents history

    /// Replays FSEvents for `sources` since `eventID` until the history is done. Folders that `skip`
    /// returns true for are dropped. Waits at most `timeout`.
    public static func history(
        since eventID: UInt64, sources: [String], skip: @escaping @Sendable (String) -> Bool = { _ in false },
        timeout: TimeInterval = 120
    ) async -> ChangeHistory {
        let collector = HistoryCollector(sources: sources.map(canonical), skip: skip)
        return await withCheckedContinuation { (cont: CheckedContinuation<ChangeHistory, Never>) in
            collector.start(since: eventID, timeout: timeout) { cont.resume(returning: $0) }
        }
    }

    /// The real path of a folder, also when it no longer exists: the nearest existing parent is
    /// resolved and the rest is appended.
    static func canonical(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        var tail: [String] = []
        var cur = p
        while !cur.isEmpty, cur != "/" {
            if let r = realpath(cur, nil) {
                defer { free(r) }
                let base = String(cString: r)
                return tail.isEmpty ? base : (base == "/" ? "" : base) + "/" + tail.reversed().joined(separator: "/")
            }
            tail.append((cur as NSString).lastPathComponent)
            cur = (cur as NSString).deletingLastPathComponent
        }
        return p
    }

    /// True when `path` is `root` or inside it.
    static func isInside(_ path: String, _ root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }
}

/// Collects one FSEvents history replay. The stream runs on its own queue.
final class HistoryCollector: @unchecked Sendable {
    private let sources: [String]
    private let skip: @Sendable (String) -> Bool
    private let queue = DispatchQueue(label: "nine-lives.fsevents")
    private var stream: FSEventStreamRef?
    private var result = ChangeHistory()
    private var finish: ((ChangeHistory) -> Void)?

    init(sources: [String], skip: @escaping @Sendable (String) -> Bool) {
        self.sources = sources
        self.skip = skip
    }

    func start(since eventID: UInt64, timeout: TimeInterval, done: @escaping (ChangeHistory) -> Void) {
        queue.async { [self] in
            finish = done
            var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
            guard let s = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
                guard let info else { return }
                let me = Unmanaged<HistoryCollector>.fromOpaque(info).takeUnretainedValue()
                let list = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                for i in 0..<count { me.handle(String(cString: list[i]), flags[i]) }
            }, &ctx, sources as CFArray, eventID, 0, flags) else {
                result.completed = false
                end()
                return
            }
            stream = s
            FSEventStreamSetDispatchQueue(s, queue)
            guard FSEventStreamStart(s) else {
                result.completed = false
                end()
                return
            }
            // Keeps self alive until the replay ends.
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                guard finish != nil else { return }
                result.completed = false
                end()
            }
        }
    }

    private func handle(_ raw: String, _ flags: FSEventStreamEventFlags) {
        guard finish != nil else { return }
        let f = Int(flags)
        if f & kFSEventStreamEventFlagHistoryDone != 0 {
            end()
            return
        }
        if f & kFSEventStreamEventFlagUserDropped != 0 || f & kFSEventStreamEventFlagKernelDropped != 0 {
            result.untrusted = "macOS dropped file change events"
        } else if f & kFSEventStreamEventFlagEventIdsWrapped != 0 {
            result.untrusted = "the file change history was reset"
        } else if f & kFSEventStreamEventFlagRootChanged != 0 {
            result.untrusted = "a folder to back up was moved or replaced"
        } else if f & (kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 {
            result.untrusted = "a disk was mounted inside a folder to back up"
        }
        guard !result.overflow else { return }
        let path = ChangeTracker.canonical(raw)
        // Events above a source (for example a sibling folder in its parent) do not matter, but an
        // event on a parent that loses detail covers the source.
        let inside = sources.filter { ChangeTracker.isInside(path, $0) }
        let above = sources.filter { ChangeTracker.isInside($0, path) && $0 != path }
        if inside.isEmpty {
            if f & kFSEventStreamEventFlagMustScanSubDirs != 0 { for s in above { result.recursive.insert(s) } }
            return
        }
        guard !skip(path) else { return }
        if f & kFSEventStreamEventFlagMustScanSubDirs != 0 {
            result.recursive.insert(path)
        } else {
            result.folders.insert(path)
        }
        if result.folders.count + result.recursive.count > ChangeTracker.maxChangedFolders { result.overflow = true }
    }

    private func end() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        let done = finish
        finish = nil
        done?(result)
    }
}

/// A quick check against skip rules for FSEvents paths, so folders that are not backed up are not
/// counted. The engine applies the real filter; this only has to avoid counting obvious noise.
public struct PathSkipper: Sendable {
    let prefixes: [String]
    let names: [[String]]
    /// Paths the user chose to keep. Nothing on the way to them, or inside them, is skipped.
    let kept: [String]

    public init(patterns: [String], includes: [String] = []) {
        kept = includes
        let glob = CharacterSet(charactersIn: "*?[\\")
        var prefixes: [String] = []
        var names: [[String]] = []
        for p in patterns where !p.hasPrefix("!") && p.rangeOfCharacter(from: glob) == nil {
            if p.hasPrefix("/") { prefixes.append(p) } else { names.append(p.split(separator: "/").map(String.init)) }
        }
        self.prefixes = prefixes
        self.names = names
    }

    public func skips(_ path: String) -> Bool {
        if kept.contains(where: { ChangeTracker.isInside(path, $0) || ChangeTracker.isInside($0, path) }) { return false }
        if prefixes.contains(where: { ChangeTracker.isInside(path, $0) }) { return true }
        let parts = path.split(separator: "/").map(String.init)
        return names.contains { n in
            guard !n.isEmpty, n.count <= parts.count else { return false }
            return (0...(parts.count - n.count)).contains { Array(parts[$0..<$0 + n.count]) == n }
        }
    }
}
