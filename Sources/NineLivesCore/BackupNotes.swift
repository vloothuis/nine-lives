import Foundation

/// Backup warnings grouped by folder and cause, so the app can explain them and offer a fix.
public struct BackupNoteGroup: Identifiable, Equatable, Sendable {
    public enum Cause: Sendable, Equatable {
        /// The file belongs to another user or has restrictive permissions. Full Disk Access does not help.
        case unreadable
        /// macOS privacy protection blocked access. Full Disk Access helps.
        case protected
        /// The Mac was busy: a system call was interrupted or no file handles were free. A later backup tries again.
        case busy
        /// Anything Nine Lives cannot classify.
        case other
    }

    public var cause: Cause
    /// The folder that holds the affected items, or nil when no path was found.
    /// When several folders follow one pattern, the parts that differ are shown with `*`.
    public var folder: String?
    /// The real folders this group covers.
    public var folders: [String] = []
    public var paths: [String]
    public var messages: [String]
    /// A restic exclude pattern that matches every folder of the group.
    public var pattern: String?
    /// What the pattern matched in the last backup besides these folders. Nil when that is not known.
    public var extra: FolderIndex.Extra?

    public var id: String { "\(cause)|\(folder ?? messages.first ?? "")" }

    public init(cause: Cause, folder: String?, folders: [String]? = nil, paths: [String], messages: [String],
                pattern: String? = nil, extra: FolderIndex.Extra? = nil) {
        self.cause = cause
        self.folder = folder
        self.folders = folders ?? folder.map { [$0] } ?? []
        self.paths = paths
        self.messages = messages
        self.pattern = pattern ?? folder.map(BackupNotes.escapedPattern)
        self.extra = extra
    }
}

public enum BackupNotes {
    /// Items a pattern may match besides the failing folders, for example an empty sibling folder.
    public static let extraBudget = 10

    /// Groups restic warnings. Files that vanished while the backup ran are normal and left out.
    /// With an index of the same backup, folders that follow one pattern are merged when the
    /// pattern matches little else. Without one, only folders that differ in one name are merged.
    public static func group(_ messages: [String], index: FolderIndex? = nil,
                             home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [BackupNoteGroup] {
        var groups: [BackupNoteGroup] = []
        for m in messages {
            let lower = m.lowercased()
            if lower.hasSuffix("no such file or directory") { continue }
            let cause: BackupNoteGroup.Cause =
                lower.hasSuffix("operation not permitted") ? .protected :
                lower.hasSuffix("permission denied") ? .unreadable :
                busySuffixes.contains(where: lower.hasSuffix) ? .busy : .other
            // Notes also hold free text, such as maintenance warnings. Only the form an item error
            // has is read as a path, so a sentence never becomes a folder to skip.
            let path = cause == .unreadable || cause == .protected ? path(in: m)
                     : itemErrorPrefixes.contains(where: m.hasPrefix) ? path(in: m) : nil
            let folder = path.map { ($0 as NSString).deletingLastPathComponent }
            if let folder, let i = groups.firstIndex(where: { $0.cause == cause && $0.folder == folder }) {
                if let path, !groups[i].paths.contains(path) { groups[i].paths.append(path) }
                if !groups[i].messages.contains(m) { groups[i].messages.append(m) }
            } else {
                groups.append(BackupNoteGroup(cause: cause, folder: folder, paths: path.map { [$0] } ?? [], messages: [m]))
            }
        }
        if let index {
            for i in groups.indices where groups[i].cause != .other {
                groups[i].extra = groups[i].pattern.flatMap { index.extra(of: $0, besides: groups[i].folders) }
            }
        }
        return merge(groups, index: index, home: home)
    }

    static let busySuffixes = ["interrupted system call", "too many open files in system", "too many open files"]
    /// How item errors start: nl-engine's `read /path: ...` and restic's `open /path: ...` or `lstat /path: ...`.
    static let itemErrorPrefixes = ["read /", "open /", "lstat /"]

    /// Merges pairs of groups as long as some pair has an acceptable common pattern.
    static func merge(_ input: [BackupNoteGroup], index: FolderIndex?, home: String) -> [BackupNoteGroup] {
        var groups = input
        // Merging compares every pair, so very long lists are left as they are.
        guard groups.count <= 300 else { return groups }
        var merged = true
        while merged {
            merged = false
            outer: for i in groups.indices {
                for j in groups.indices where j > i {
                    // Only lasting causes are merged. A busy or unknown error says little about its siblings.
                    guard groups[i].cause == groups[j].cause, groups[i].cause == .unreadable || groups[i].cause == .protected else { continue }
                    let folders = groups[i].folders + groups[j].folders.filter { !groups[i].folders.contains($0) }
                    guard let c = generalize(folders, lastMayDiffer: index != nil),
                          canSkip(prefixOf: c.display, home: home) else { continue }
                    var extra: FolderIndex.Extra?
                    if let index {
                        guard let e = index.extra(of: c.pattern, besides: folders),
                              !e.unknown, e.items <= extraBudget else { continue }
                        extra = e
                    } else {
                        guard c.slots == 1 else { continue }
                    }
                    groups[i].folder = c.display
                    groups[i].pattern = c.pattern
                    groups[i].extra = extra
                    groups[i].folders = folders
                    groups[i].paths += groups[j].paths.filter { !groups[i].paths.contains($0) }
                    groups[i].messages += groups[j].messages.filter { !groups[i].messages.contains($0) }
                    groups.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        return groups
    }

    struct Candidate: Equatable {
        /// The restic pattern.
        var pattern: String
        /// The same pattern for people, with `*` where folders differ and no escapes.
        var display: String
        /// How many path components differ.
        var slots: Int
    }

    /// The narrowest pattern that matches all folders. They need the same depth. Where names differ,
    /// their shared start and end are kept and the middle becomes `*`. The last name may only differ
    /// when an index can check what else the pattern matches, because `/Projects/*` would skip every project.
    static func generalize(_ folders: [String], lastMayDiffer: Bool = false) -> Candidate? {
        let split = folders.map { $0.split(separator: "/", omittingEmptySubsequences: false).map(String.init) }
        guard let first = split.first, split.count > 1, split.allSatisfy({ $0.count == first.count }),
              lastMayDiffer || split.allSatisfy({ $0.last == first.last }) else { return nil }
        var pattern: [String] = [], display: [String] = [], slots = 0
        for k in first.indices {
            let values = split.map { $0[k] }
            if values.allSatisfy({ $0 == values[0] }) {
                pattern.append(escapedPattern(values[0]))
                display.append(values[0])
                continue
            }
            slots += 1
            let pre = commonPrefix(values)
            let rest = values.map { String($0.dropFirst(pre.count)) }
            let maxSuffix = rest.map(\.count).min() ?? 0
            let suf = String(commonPrefix(rest.map { String($0.reversed()) }).reversed().suffix(maxSuffix))
            pattern.append(escapedPattern(pre) + "*" + escapedPattern(suf))
            display.append(pre + "*" + suf)
        }
        return Candidate(pattern: pattern.joined(separator: "/"), display: display.joined(separator: "/"), slots: slots)
    }

    static func commonPrefix(_ values: [String]) -> String {
        guard var p = values.first else { return "" }
        for v in values.dropFirst() {
            p = String(zip(p, v).prefix { $0 == $1 }.map(\.0))
        }
        return p
    }

    /// False when the part before the first `*` is too broad to skip.
    static func canSkip(prefixOf display: String, home: String) -> Bool {
        guard let star = display.firstIndex(of: "*") else { return canSkip(display, home: home) }
        let before = display[..<star]
        guard let slash = before.lastIndex(of: "/") else { return false }
        return canSkip(String(before[..<slash]), home: home)
    }

    /// False when the group's pattern could cover the home folder or one of its parents.
    public static func canSkip(_ group: BackupNoteGroup, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        guard let folder = group.folder else { return false }
        return canSkip(prefixOf: folder, home: home)
    }

    /// False for folders too broad to skip from a note, such as the home folder or one of its parents.
    public static func canSkip(_ folder: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        let f = (folder as NSString).standardizingPath
        guard f.hasPrefix("/"), f != "/" else { return false }
        return !(home == f || home.hasPrefix(f + "/"))
    }

    /// The path as a restic exclude pattern that matches only itself.
    public static func escapedPattern(_ path: String) -> String {
        var out = ""
        for ch in path {
            if "*?[]\\".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// The absolute path in a message such as "open /a/b: permission denied".
    static func path(in message: String) -> String? {
        guard let start = message.range(of: " /"), let end = message.range(of: ": ", options: .backwards),
              start.upperBound <= end.lowerBound else { return nil }
        return String(message[message.index(before: start.upperBound)..<end.lowerBound])
    }
}
