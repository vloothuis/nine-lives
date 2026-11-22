import SwiftUI
import NineLivesCore

struct OverviewView: View {
    @Environment(BackupCoordinator.self) private var c
    @State private var showAddDisk = false
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusCard
                if !c.optionalFindings.isEmpty { optionalCard }
                if case .backingUp(let id, let info) = c.activity { progressCard(id: id, info: info) }
                if case .verifying(_, let text) = c.activity {
                    Card { HStack { ProgressView().controlSize(.small); Text(text) } }
                }
                if case .working(let text) = c.activity {
                    Card { HStack { ProgressView().controlSize(.small); Text(text) } }
                }
                if !c.state.disks.isEmpty { disksSection }
                notes
            }
            .padding(24)
        }
        .navigationTitle("Overview")
        .sheet(isPresented: $showAddDisk) { AddDiskSheet() }
    }

    private var statusCard: some View {
        Card {
            HStack(spacing: 16) {
                StatusSymbol(status: c.status).frame(width: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle(c.status)).font(.title2.weight(.semibold))
                    subtitle
                }
                Spacer()
                if case .needsSetup = c.status {
                    Button("Add Disk…") { showAddDisk = true }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
    }

    private var optionalCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Large items are not backed up yet").font(.headline)
                Text("Choose for a whole kind, or open it to choose per item. You can change this later in Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(c.optionalFindings) { f in
                    Divider()
                    optionalGroup(f)
                }
            }
        }
    }

    @ViewBuilder private func optionalGroup(_ f: OptionalFinding) -> some View {
        let sizeText = ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)
        if f.items.count == 1, let item = f.items.first {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.title).fontWeight(.medium)
                    Text("\(displayPath(item.path)), \(sizeText)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Skip") { c.answerOptional(f, backUp: false) }
                Button("Back Up") { c.answerOptional(f, backUp: true) }.buttonStyle(.borderedProminent)
            }
        } else {
            DisclosureGroup(isExpanded: Binding(get: { !collapsedGroups.contains(f.id) },
                                                set: { open in
                                                    if open { collapsedGroups.remove(f.id) } else { collapsedGroups.insert(f.id) }
                                                })) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(f.items) { item in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: item.path).lastPathComponent)
                                Text("\(displayPath(item.path)), \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("Skip") { c.answerOptional(item, in: f, backUp: false) }.controlSize(.small)
                            Button("Back Up") { c.answerOptional(item, in: f, backUp: true) }.controlSize(.small)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.title).fontWeight(.medium)
                        Text("\(f.items.count) items, \(sizeText)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Skip All") { c.answerOptional(f, backUp: false) }
                    Button("Back Up All") { c.answerOptional(f, backUp: true) }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func displayPath(_ p: String) -> String {
        p.hasPrefix(NSHomeDirectory()) ? "~" + p.dropFirst(NSHomeDirectory().count) : p
    }

    @ViewBuilder private var subtitle: some View {
        switch c.status {
        case .ok, .warning:
            if let last = c.latestSuccess {
                HStack(spacing: 3) { Text("Last backup"); RelativeDateText(date: last) }.foregroundStyle(.secondary)
            } else {
                Text("Plug in a backup disk to make your first backup.").foregroundStyle(.secondary)
            }
        case .error(let m): Text(m).foregroundStyle(.secondary)
        case .needsSetup: Text("Use a USB disk. Nine Lives does the rest.").foregroundStyle(.secondary)
        case .running: EmptyView()
        }
    }

    private func progressCard(id: String, info: ProgressInfo) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Backing up to \(c.disk(id)?.name ?? "disk")").font(.headline)
                    Spacer()
                    Button("Stop") { c.cancelCurrent() }
                }
                if let f = info.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                Text("\(info.files.formatted()) files · \(Fmt.bytes(info.bytes)) checked" + (info.sentBytes > 0 ? " · \(Fmt.bytes(info.sentBytes)) sent" : ""))
                    .font(.callout).foregroundStyle(.secondary)
                Text(info.currentPath).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var disksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Backup disks").font(.headline)
            ForEach(c.state.disks) { disk in
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: disk.symbol(connected: c.isConnected(disk)))
                            .font(.title2)
                            .foregroundStyle(c.isConnected(disk) ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(disk.name).font(.body.weight(.medium))
                            if let last = disk.lastBackup {
                                HStack(spacing: 3) { Text("Last backup"); RelativeDateText(date: last) }
                                    .font(.callout).foregroundStyle(.secondary)
                            } else {
                                Text("No backup yet").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if c.isConnected(disk) {
                            Button("Back Up Now") { c.startBackup(diskID: disk.id, trigger: .manual) }
                                .disabled(!c.activity.isIdle || !c.engineAvailable)
                        } else if c.monitor.loaded {
                            Label(disk.offlineText, systemImage: disk.isRemote ? "wifi.slash" : "cable.connector.slash").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var notes: some View {
        if let last = c.state.history.first, !last.messages.isEmpty, last.outcome != .cancelled {
            VStack(alignment: .leading, spacing: 8) {
                Text(last.outcome == .failed ? "What went wrong" : "Notes from the last backup").font(.headline)
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        if last.outcome == .failed, let m = last.messages.first {
                            ErrorBox(error: ShownError(m, details: last.details))
                        } else {
                        ForEach(Array(last.messages.prefix(6).enumerated()), id: \.offset) { _, m in
                            Text(m).font(.callout).textSelection(.enabled)
                        }
                        if last.messages.count > 6 {
                            Text("And \(last.messages.count - 6) more in Activity.").font(.callout).foregroundStyle(.secondary)
                        }
                        }
                        if last.outcome == .warning, last.messages.contains(where: { $0.contains("Permission denied") || $0.contains("Operation not permitted") }) {
                            Button("Open Full Disk Access Settings") { Permissions.openFullDiskAccessSettings() }
                        }
                    }
                }
            }
        }
    }
}
