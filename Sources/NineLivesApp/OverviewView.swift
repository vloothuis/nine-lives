import SwiftUI
import NineLivesCore

struct OverviewView: View {
    @Environment(BackupCoordinator.self) private var c
    @Environment(\.openWindow) private var openWindow
    @State private var showAddDisk = false
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if c.fullDiskAccessLost { accessLostCard }
                statusCard
                if !c.optionalFindings.isEmpty { optionalCard }
                if case .backingUp(let id, let info) = c.activity { progressCard(id: id, info: info) }
                if case .verifying(_, let text) = c.activity {
                    Card { HStack { ProgressView().controlSize(.small); Text(text) } }
                }
                if case .working(let text) = c.activity {
                    Card { HStack { ProgressView().controlSize(.small); Text(text) } }
                }
                notes
                if !c.state.disks.isEmpty { DisksSection() }
            }
            .padding(24)
        }
        .navigationTitle("Nine Lives")
        .toolbar {
            ToolbarItemGroup {
                Button { openWindow(id: WindowID.restore) } label: {
                    Label("Restore Files", systemImage: "clock.arrow.circlepath")
                }
                .help("Browse your backups and restore files")
                Button { openWindow(id: WindowID.activity) } label: {
                    Label("Activity", systemImage: "list.bullet.rectangle")
                }
                .help("Show past backups and checks")
                Button { showAddDisk = true } label: {
                    Label("Add Disk", systemImage: "plus")
                }
                .help("Add a backup disk or server")
            }
        }
        .sheet(isPresented: $showAddDisk) { AddDiskSheet() }
    }

    private var accessLostCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Nine Lives lost Full Disk Access", systemImage: "lock.shield.fill").font(.headline)
                Text("macOS often turns it off when the app is updated. Until you turn it on again, backups skip Mail, Photos, Safari and other private data.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("If Nine Lives still shows as on in System Settings, turn it off and on again, or remove it with the minus button and add it again.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Open Full Disk Access Settings") { Permissions.openFullDiskAccessSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("Check Again") { c.checkFullDiskAccess() }
                }
            }
        }
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
                    if info.lowPriority {
                        Button("Speed Up") { c.speedUpCurrent() }
                            .help("Let this backup use more of your Mac. It may slow down other apps until it ends.")
                    }
                    Button("Stop") { c.cancelCurrent() }
                }
                if let f = info.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                Text("\(info.files.formatted()) files · \(Fmt.bytes(info.bytes)) checked" + (info.sentBytes > 0 ? " · \(Fmt.bytes(info.sentBytes)) sent" : ""))
                    .font(.callout).foregroundStyle(.secondary)
                Text(info.currentPath).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
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
                            let groups = c.noteGroups(for: last)
                            ForEach(groups.prefix(5)) { g in noteRow(g) }
                            if groups.count > 5 {
                                HStack(spacing: 4) {
                                    Text("And \(groups.count - 5) more.")
                                    Button("Show in Activity") { openWindow(id: WindowID.activity) }.buttonStyle(.link)
                                }
                                .font(.callout).foregroundStyle(.secondary)
                            }
                            if groups.isEmpty {
                                Text("Some files changed or disappeared while the backup ran. This is normal.").font(.callout)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func noteRow(_ g: BackupNoteGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch g.cause {
            case .unreadable:
                let folder = displayPath(g.folder ?? "")
                let place = g.folders.count > 1 ? "\(g.folders.count) folders like \(folder)" : folder
                Text(g.paths.count == 1 ? "1 item in \(place) could not be read."
                                        : "\(g.paths.count) items in \(place) could not be read.")
                    .font(.callout.weight(.medium))
                Text("They belong to another user or only their owner may open them. This is often temporary data left by a tool. Skip the folder if you do not need it in your backup.")
                    .font(.callout).foregroundStyle(.secondary)
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
            case .protected:
                Text("macOS blocked access to \(g.paths.count == 1 ? "1 item" : "\(g.paths.count) items") in \(displayPath(g.folder ?? "")).")
                    .font(.callout.weight(.medium))
                Text("Give Nine Lives Full Disk Access to back these up.").font(.callout).foregroundStyle(.secondary)
                Button("Open Full Disk Access Settings") { Permissions.openFullDiskAccessSettings() }
            case .other:
                ForEach(g.messages, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
            }
        }
        .help(g.paths.joined(separator: "\n"))
    }
}
