import SwiftUI
import NineLivesCore

/// Past backups in a list, with the selected backup's details next to it.
struct ActivityView: View {
    @Environment(BackupCoordinator.self) private var c
    @State private var selection: BackupRecord.ID?

    private var selected: BackupRecord? {
        c.state.history.first { $0.id == selection }
    }

    var body: some View {
        Group {
            if c.state.history.isEmpty {
                ContentUnavailableView("No backups yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Finished backups show up here."))
            } else {
                HSplitView {
                    List(c.state.history, selection: $selection) { record in
                        RecordRow(record: record).tag(record.id)
                    }
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                    Group {
                        if let selected {
                            RecordDetail(record: selected).id(selected.id)
                        } else {
                            ContentUnavailableView("Select a backup", systemImage: "sidebar.left",
                                                   description: Text("Its details show here."))
                        }
                    }
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Activity")
        .onAppear { if selection == nil { selection = c.state.history.first?.id } }
    }
}

private extension BackupRecord {
    var icon: (String, Color) {
        switch outcome {
        case .success: ("checkmark.circle.fill", .green)
        case .warning: ("exclamationmark.triangle.fill", .orange)
        case .failed: ("xmark.octagon.fill", .red)
        case .cancelled: ("stop.circle.fill", .secondary)
        case .skipped: ("arrow.uturn.forward.circle", .secondary)
        }
    }

    var title: String {
        let what = switch kind {
        case .quick: "Quick backup"
        case .full: "Full backup"
        case nil: "Backup"
        }
        return switch outcome {
        case .success: "\(what) to \(diskName)"
        case .warning: "\(what) to \(diskName) with notes"
        case .failed: "\(what) to \(diskName) failed"
        case .cancelled: "\(what) to \(diskName) stopped"
        case .skipped: "\(what) to \(diskName) skipped"
        }
    }

    /// Explains the two kinds of backup in the details.
    var kindText: String? {
        switch kind {
        case .quick: "Only folders that changed since the last backup were read."
        case .full: "Every folder was checked."
        case nil: nil
        }
    }

    /// What follows the date in the list.
    var caption: String {
        if outcome == .skipped { return (repeats ?? 1) > 1 ? " · \(repeats ?? 1) times" : "" }
        return messages.isEmpty ? "" : " · \(messages.count) note\(messages.count == 1 ? "" : "s")"
    }

    var triggerText: String {
        switch trigger {
        case .manual: "Started by you"
        case .plugIn: "Disk was plugged in"
        case .scheduled: "Scheduled"
        }
    }
}

private struct RecordRow: View {
    let record: BackupRecord

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: record.icon.0).foregroundStyle(record.icon.1).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).lineLimit(1)
                Text(record.start.formatted(date: .abbreviated, time: .shortened) + record.caption)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RecordDetail: View {
    @Environment(BackupCoordinator.self) private var c
    let record: BackupRecord

    private var messageList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(record.messages.enumerated()), id: \.offset) { _, m in
                Text(m).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: record.icon.0).font(.title).foregroundStyle(record.icon.1)
                    Text(record.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Started", record.start.formatted(date: .abbreviated, time: .standard))
                    row("Took", Fmt.duration(record.end.timeIntervalSince(record.start)))
                    row("Why", record.triggerText)
                    if let since = record.skippedSince, let n = record.repeats {
                        row("Skipped", "\(n) times since \(since.formatted(date: .abbreviated, time: .shortened))")
                    }
                    if let k = record.kindText { row("Kind", k) }
                    if let stats = record.statsLike { row("Result", Fmt.summary(stats)) }
                    if let name = record.archiveName { row("Snapshot", name) }
                }
                .font(.callout)

                if !record.messages.isEmpty {
                    if record.outcome == .skipped {
                        messageList
                    } else if record.outcome == .failed {
                        section("What went wrong", copy: record.messages.joined(separator: "\n")) { messageList }
                    } else {
                        let groups = c.noteGroups(for: record)
                        if !groups.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Notes").font(.headline)
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(groups) { g in NoteRow(group: g, record: record) }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            }
                        } else {
                            Text("Some files changed or disappeared while the backup ran. This is normal.").font(.callout)
                        }
                        DisclosureGroup("All messages (\(record.messages.count))") {
                            HStack {
                                Spacer()
                                Button("Copy") { copyToPasteboard(record.messages.joined(separator: "\n")) }
                                    .buttonStyle(.link).font(.callout)
                            }
                            messageList
                                .padding(10)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                if let details = record.details, !details.isEmpty, record.outcome == .skipped {
                    // Nothing to worry about, so the raw output stays folded away for those who want it.
                    DisclosureGroup("Technical details") {
                        HStack {
                            Spacer()
                            Button("Copy") { copyToPasteboard(details) }.buttonStyle(.link).font(.callout)
                        }
                        Text(details).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                } else if let details = record.details, !details.isEmpty {
                    section("Technical details", copy: details) {
                        Text(details).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if record.messages.isEmpty, record.details == nil {
                    Text(record.outcome == .cancelled ? "The backup was stopped before it finished." : "Nothing to report.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }

    private func section<Content: View>(_ title: String, copy: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Copy") { copyToPasteboard(copy) }.buttonStyle(.link).font(.callout)
            }
            content()
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
