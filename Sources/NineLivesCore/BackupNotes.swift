import Foundation

/// Backup warnings grouped by folder and cause, so the app can explain them and offer a fix.
public struct BackupNoteGroup: Identifiable, Equatable, Sendable {
    public enum Cause: Sendable, Equatable {
        /// The file belongs to another user or has restrictive permissions. Full Disk Access does not help.
        case unreadable
        /// macOS privacy protection blocked access. Full Disk Access helps.
        case protected
        /// Anything Nine Lives cannot classify.
        case other
    }

    public var cause: Cause
    /// The folder that holds the affected items, or nil when no path was found.
    public var folder: String?
    public var paths: [String]
    public var messages: [String]

    public var id: String { "\(cause)|\(folder ?? messages.first ?? "")" }
}

public enum BackupNotes {
    /// Groups restic warnings. Files that vanished while the backup ran are normal and left out.
    public static func group(_ messages: [String]) -> [BackupNoteGroup] {
        var groups: [BackupNoteGroup] = []
        for m in messages {
            let lower = m.lowercased()
            if lower.hasSuffix("no such file or directory") { continue }
            let cause: BackupNoteGroup.Cause =
                lower.hasSuffix("operation not permitted") ? .protected :
                lower.hasSuffix("permission denied") ? .unreadable : .other
            let path = cause == .other ? nil : path(in: m)
            let folder = path.map { ($0 as NSString).deletingLastPathComponent }
            if let folder, let i = groups.firstIndex(where: { $0.cause == cause && $0.folder == folder }) {
                if let path, !groups[i].paths.contains(path) { groups[i].paths.append(path) }
                if !groups[i].messages.contains(m) { groups[i].messages.append(m) }
            } else {
                groups.append(BackupNoteGroup(cause: cause, folder: folder, paths: path.map { [$0] } ?? [], messages: [m]))
            }
        }
        return groups
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
