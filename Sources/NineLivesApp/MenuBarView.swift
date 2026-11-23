import SwiftUI
import NineLivesCore

struct MenuBarView: View {
    @Environment(BackupCoordinator.self) private var c
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                StatusSymbol(status: c.status, size: 28).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle(c.status)).font(.headline)
                    if let last = c.latestSuccess, !isRunning {
                        HStack(spacing: 3) { Text("Last backup"); RelativeDateText(date: last) }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if case .backingUp(let id, let info) = c.activity {
                VStack(alignment: .leading, spacing: 4) {
                    if let f = info.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                    Text("\(c.disk(id)?.name ?? "Disk") · \(info.files.formatted()) files")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if info.lowPriority { Button("Speed Up") { c.speedUpCurrent() } }
                        Button("Stop") { c.cancelCurrent() }
                    }
                    .controlSize(.small)
                }
            }

            if !c.state.disks.isEmpty {
                Divider()
                ForEach(c.state.disks) { disk in
                    HStack {
                        Image(systemName: disk.symbol(connected: c.isConnected(disk)))
                            .foregroundStyle(c.isConnected(disk) ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(disk.name)
                            HStack(spacing: 3) {
                                if let last = disk.lastBackup { RelativeDateText(date: last) } else { Text("No backup yet") }
                                if c.unreachableServers.contains(disk.id) {
                                    Text("· not reachable").foregroundStyle(.orange)
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if c.isConnected(disk) {
                            Button("Back Up") { c.startBackup(diskID: disk.id, trigger: .manual) }
                                .disabled(!c.activity.isIdle)
                        } else if c.monitor.loaded {
                            Text(disk.offlineText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 2) {
                menuButton("Open Nine Lives") { show(WindowID.main) }
                menuButton("Restore Files…") { show(WindowID.restore) }
                menuButton("Activity") { show(WindowID.activity) }
                menuButton("Settings…") { NSApp.activate(); openSettings() }
                menuButton("About Nine Lives") { AboutPanel.show() }
                menuButton("Quit Nine Lives") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var isRunning: Bool { if case .running = c.status { true } else { false } }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }

    private func menuButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}
