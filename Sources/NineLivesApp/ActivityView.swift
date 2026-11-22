import SwiftUI
import NineLivesCore

struct ActivityView: View {
    @Environment(BackupCoordinator.self) private var c

    var body: some View {
        Group {
            if c.state.history.isEmpty {
                ContentUnavailableView("No backups yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Finished backups show up here."))
            } else {
                List(c.state.history) { record in
                    RecordRow(record: record)
                }
            }
        }
        .navigationTitle("Activity")
    }
}

private struct RecordRow: View {
    let record: BackupRecord

    var icon: (String, Color) {
        switch record.outcome {
        case .success: ("checkmark.circle.fill", .green)
        case .warning: ("exclamationmark.triangle.fill", .orange)
        case .failed: ("xmark.octagon.fill", .red)
        case .cancelled: ("stop.circle.fill", .secondary)
        }
    }

    var title: String {
        switch record.outcome {
        case .success: "Backup to \(record.diskName)"
        case .warning: "Backup to \(record.diskName) with notes"
        case .failed: "Backup to \(record.diskName) failed"
        case .cancelled: "Backup to \(record.diskName) stopped"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Image(systemName: icon.0).foregroundStyle(icon.1).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text("\(record.start.formatted(date: .abbreviated, time: .shortened)) · \(Fmt.duration(record.end.timeIntervalSince(record.start)))"
                         + (record.statsLike.map { " · " + Fmt.summary($0) } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if record.outcome == .failed, let m = record.messages.first {
                ErrorBox(error: ShownError(m, details: record.details)).padding(.leading, 26)
            } else if !record.messages.isEmpty {
                DisclosureGroup("Details (\(record.messages.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(record.messages.enumerated()), id: \.offset) { _, m in
                            Text(m).font(.caption).textSelection(.enabled)
                        }
                    }.padding(.top, 4)
                }
                .font(.caption)
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 3)
    }
}
