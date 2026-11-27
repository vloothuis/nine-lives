import SwiftUI
import NineLivesCore

/// One group of backup notes with what the user can do about it.
struct NoteRow: View {
    @Environment(BackupCoordinator.self) private var c
    let group: BackupNoteGroup
    /// The backup the note comes from.
    let record: BackupRecord

    var body: some View {
        let g = group
        VStack(alignment: .leading, spacing: 4) {
            switch g.cause {
            case .unreadable:
                Text(g.paths.count == 1 ? "1 item in \(place) could not be read."
                                        : "\(g.paths.count) items in \(place) could not be read.")
                    .font(.callout.weight(.medium))
                Text("They belong to another user or only their owner may open them. This is often temporary data left by a tool. Skip the folder if you do not need it in your backup.")
                    .font(.callout).foregroundStyle(.secondary)
                skipControls
            case .protected:
                Text("macOS blocked access to \(g.paths.count == 1 ? "1 item" : "\(g.paths.count) items") in \(place).")
                    .font(.callout.weight(.medium))
                if record.fullDiskAccess ?? Permissions.hasFullDiskAccess() {
                    Text("Nine Lives has Full Disk Access, but macOS keeps some private data, such as Safari activity, from every app. These items cannot be backed up. Skip the folder to stop this note.")
                        .font(.callout).foregroundStyle(.secondary)
                    skipControls
                } else if Permissions.hasFullDiskAccess() {
                    Text("Full Disk Access is on now, so the next backup tries these again.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Give Nine Lives Full Disk Access to back these up.").font(.callout).foregroundStyle(.secondary)
                    Button("Open Full Disk Access Settings") { Permissions.openFullDiskAccessSettings() }
                }
            case .other:
                ForEach(g.messages, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
            }
        }
        .help(g.paths.joined(separator: "\n"))
    }

    private var folder: String { displayPath(group.folder ?? "") }

    private var place: String {
        group.folders.count > 1 ? "\(group.folders.count) folders like \(folder)" : folder
    }

    @ViewBuilder private var skipControls: some View {
        let g = group
        if BackupNotes.canSkip(g) {
            if c.isSkipped(g) {
                Text("Skipped from the next backup on.").font(.callout).foregroundStyle(.secondary)
            } else {
                Button(g.folders.count > 1 ? "Skip all \(g.folders.count) folders" : "Skip \(folder)") { c.skip(g) }
                    .help(g.folders.joined(separator: "\n"))
                if g.folders.count > 1, let e = g.extra {
                    Text(e.folders == 0
                         ? "In the last backup, this skips these folders and nothing else."
                         : "In the last backup, this also skips \(e.folders == 1 ? "1 other folder" : "\(e.folders) other folders") with \(e.items == 1 ? "1 item" : "\(e.items.formatted()) items").")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func displayPath(_ p: String) -> String {
        p.hasPrefix(NSHomeDirectory()) ? "~" + p.dropFirst(NSHomeDirectory().count) : p
    }
}
