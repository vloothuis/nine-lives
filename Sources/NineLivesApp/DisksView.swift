import SwiftUI
import NineLivesCore

struct DisksView: View {
    @Environment(BackupCoordinator.self) private var c
    @State private var showAdd = false
    @State private var forgetting: KnownDisk?
    @State private var showingPassphrase: KnownDisk?
    @State private var ejectError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if c.state.disks.isEmpty {
                    ContentUnavailableView("No backup disks", systemImage: "externaldrive.badge.plus",
                                           description: Text("Add a USB disk to start backing up."))
                        .frame(maxWidth: .infinity)
                }
                ForEach(c.state.disks) { disk in diskCard(disk) }
                if c.state.disks.count == 1 {
                    Label("Tip: add a second disk and keep it somewhere else, for example at work. Nine Lives backs up whichever disk is connected.",
                          systemImage: "lightbulb")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .navigationTitle("Disks")
        .toolbar {
            ToolbarItem { Button { showAdd = true } label: { Label("Add Disk", systemImage: "plus") } }
        }
        .sheet(isPresented: $showAdd) { AddDiskSheet() }
        .sheet(item: $showingPassphrase) { disk in PassphraseSheet(disk: disk) }
        .confirmationDialog("Forget \(forgetting?.name ?? "disk")?", isPresented: Binding(
            get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), presenting: forgetting) { disk in
            Button("Forget Disk", role: .destructive) { c.forgetDisk(disk.id) }
        } message: { _ in
            Text("Nine Lives stops using this disk. The backups on it are not deleted, and you can add the disk again later.")
        }
        .alert("Could not eject", isPresented: Binding(get: { ejectError != nil }, set: { if !$0 { ejectError = nil } })) {
            Button("OK") {}
        } message: { Text(ejectError ?? "") }
    }

    private func diskCard(_ disk: KnownDisk) -> some View {
        let connected = c.isConnected(disk)
        let volume = c.connectedVolume(for: disk)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: disk.symbol(connected: connected)).font(.title)
                        .foregroundStyle(connected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading) {
                        Text(disk.name).font(.title3.weight(.semibold))
                        Text(!c.monitor.loaded ? "Checking…" : connected ? disk.onlineText : disk.offlineText).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if connected {
                        Button("Back Up Now") { c.startBackup(diskID: disk.id, trigger: .manual) }
                            .disabled(!c.activity.isIdle || !c.engineAvailable)
                    }
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                    row("Last backup", disk.lastBackup.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                    if let s = disk.storedSize { row("Backups use", Fmt.bytes(s)) }
                    if let v = volume ?? nil { row("Free space", Fmt.bytes(v.availableCapacity)) }
                    if let s = disk.remote { row("Server", "\(s.display), \(s.path)") }
                    row("Protection", disk.mode == .authenticated
                        ? "Disk is encrypted. Backups are tamper-proof."
                        : "Backups are encrypted with a passphrase.")
                    row("Last check", disk.lastVerification.map { v in
                        (v.passed ? "Passed" : "Problem found") + ", " + v.date.formatted(date: .abbreviated, time: .omitted)
                    } ?? "Not yet")
                }
                .font(.callout)
                HStack {
                    Button("Check Backups") { c.startVerification(diskID: disk.id) }
                        .disabled(!connected || !c.activity.isIdle)
                    if connected, !disk.isRemote {
                        Button("Eject") {
                            do { try c.eject(disk) } catch { ejectError = error.localizedDescription }
                        }.disabled(!c.activity.isIdle)
                    }
                    if disk.mode == .repokey {
                        Button("Show Recovery Passphrase…") { showingPassphrase = disk }
                    }
                    Spacer()
                    Button("Forget…", role: .destructive) { forgetting = disk }
                }
                if let v = disk.lastVerification, !v.passed {
                    ForEach(Array(v.problems.enumerated()), id: \.offset) { _, p in
                        Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value)
        }
    }
}

struct PassphraseSheet: View {
    @Environment(BackupCoordinator.self) private var c
    @Environment(\.dismiss) private var dismiss
    let disk: KnownDisk

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recovery passphrase for \(disk.name)").font(.title3.weight(.semibold))
            Text("You need this passphrase to read your backups on another Mac, or after reinstalling macOS. Keep a copy somewhere safe, away from the disk.")
                .foregroundStyle(.secondary)
            if let p = c.recoveryPassphrase(for: disk) {
                Text(p).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("Copy") { copyToPasteboard(p) }
                    Button("Save as File…") { savePassphrase(p, diskName: disk.name) }
                }
            } else {
                Text("The passphrase is not in this Mac's Keychain.").foregroundStyle(.orange)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 460)
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func savePassphrase(_ passphrase: String, diskName: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Nine Lives recovery passphrase.txt"
    panel.message = "Save this file somewhere safe, not on the backup disk."
    if panel.runModal() == .OK, let url = panel.url {
        let text = "Nine Lives recovery passphrase for \(diskName):\n\n\(passphrase)\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
