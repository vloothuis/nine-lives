import SwiftUI
import BorgKit
import NineLivesCore

struct SettingsView: View {
    @Environment(BackupCoordinator.self) private var c
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?
    @State private var borgVersion = ""

    private func binding<T>(_ kp: WritableKeyPath<BackupSettings, T>) -> Binding<T> {
        Binding(get: { c.state.settings[keyPath: kp] }, set: { v in c.updateSettings { $0[keyPath: kp] = v } })
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open Nine Lives when I log in", isOn: Binding(get: { launchAtLogin }, set: { on in
                    do { try LaunchAtLogin.set(on); launchAtLogin = on; loginError = nil } catch { loginError = error.localizedDescription }
                }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Eject the disk after a backup that starts when I plug it in", isOn: binding(\.ejectAfterPlugIn))
                Toggle("Notify me when a backup finishes", isOn: binding(\.notifyOnSuccess))
                    .onChange(of: c.state.settings.notifyOnSuccess) { _, on in
                        if on { Task { _ = await c.requestNotificationPermission() } }
                    }
            }

            Section("Schedule") {
                Picker("While a disk stays connected", selection: binding(\.intervalMinutes)) {
                    Text("Back up every 30 minutes").tag(30)
                    Text("Back up every hour").tag(60)
                    Text("Back up every 3 hours").tag(180)
                    Text("Back up once a day").tag(1440)
                    Text("Only when I plug in the disk").tag(0)
                }
                Toggle("Pause on battery below 20%", isOn: binding(\.pauseOnLowBattery))
                Picker("Remind me when there is no backup for", selection: binding(\.remindAfterDays)) {
                    ForEach([3, 7, 14, 30], id: \.self) { Text("\($0) days").tag($0) }
                }
                Picker("Check that backups can be restored", selection: binding(\.verifyEveryDays)) {
                    Text("Every week").tag(7)
                    Text("Every month").tag(30)
                    Text("Every 3 months").tag(90)
                    Text("Never").tag(0)
                }
            }

            Section("History to keep") {
                Picker("Keep", selection: retentionBinding) {
                    ForEach(RetentionPreset.allCases) { Text($0.title).tag($0) }
                }
                Text(retentionDescription).font(.caption).foregroundStyle(.secondary)
            }

            Section("What to back up") {
                ForEach(c.state.settings.sources, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text(displayPath(path))
                        Spacer()
                        Button { c.updateSettings { $0.sources.removeAll { $0 == path } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).disabled(c.state.settings.sources.count < 2)
                    }
                }
                Button("Add Folder…") { addFolder { p in c.updateSettings { if !$0.sources.contains(p) { $0.sources.append(p) } } } }
            }

            Section("Skipped automatically") {
                ForEach(ruleCategories, id: \.self) { category in
                    DisclosureGroup {
                        ForEach(c.state.settings.rules.indices.filter { c.state.settings.rules[$0].category == category }, id: \.self) { i in
                            let rule = c.state.settings.rules[i]
                            Toggle(isOn: Binding(get: { c.state.settings.rules[i].enabled },
                                                 set: { v in c.updateSettings { $0.rules[i].enabled = v } })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(rule.title)
                                    if !rule.detail.isEmpty { Text(rule.detail).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    } label: {
                        Toggle(category, isOn: categoryBinding(category))
                    }
                }
                Button("Skip Another Folder…") {
                    addFolder { p in
                        c.updateSettings {
                            $0.rules.append(ExcludeRule(id: UUID().uuidString, title: displayPath(p), detail: "Added by you",
                                                        kind: .absolute, value: p, builtIn: false))
                        }
                    }
                }
                Text("Folders that contain a file named .nobackup are skipped too.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Advanced") {
                LabeledContent("Backup engine", value: c.borgAvailable ? borgVersion : "Not found")
                HStack {
                    Text(c.state.settings.borgPathOverride ?? "Using the built-in borg").foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Choose borg…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let u = panel.url { c.updateSettings { $0.borgPathOverride = u.path } }
                    }
                    if c.state.settings.borgPathOverride != nil {
                        Button("Reset") { c.updateSettings { $0.borgPathOverride = nil } }
                    }
                }
                Button("Show Data Folder in Finder") { revealInFinder(StateStore.defaultDirectory) }
            }

            Section("About") {
                Text("Nine Lives is open source software under the BSD 3-Clause license. Backups are stored with BorgBackup, so you can always restore without this app.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task(id: c.state.settings.borgPathOverride) {
            borgVersion = (try? await c.engine?.borg.version()) ?? ""
        }
    }

    /// Categories in the order the rules list them, with the user's own rules last.
    private var ruleCategories: [String] {
        var seen: [String] = []
        for r in c.state.settings.rules where !seen.contains(r.category) { seen.append(r.category) }
        return seen.filter { $0 != ExcludeRule.defaultCategory } + seen.filter { $0 == ExcludeRule.defaultCategory }
    }

    /// On when every rule in the category is on, off when none is, and a switch for the whole group.
    private func categoryBinding(_ category: String) -> Binding<Bool> {
        Binding(
            get: { c.state.settings.rules.filter { $0.category == category }.contains { $0.enabled } },
            set: { on in
                c.updateSettings { s in
                    for i in s.rules.indices where s.rules[i].category == category { s.rules[i].enabled = on }
                }
            })
    }

    private func displayPath(_ p: String) -> String {
        p.hasPrefix(NSHomeDirectory()) ? "~" + p.dropFirst(NSHomeDirectory().count) : p
    }

    private func addFolder(_ done: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let u = panel.url { done(u.path) }
    }

    // MARK: Retention

    enum RetentionPreset: String, CaseIterable, Identifiable {
        case standard, long, short, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: "Standard"
            case .long: "A long time"
            case .short: "Less, to save space"
            case .custom: "Custom"
            }
        }
        var retention: Retention? {
            switch self {
            case .standard: Retention()
            case .long: Retention(hourly: 24, daily: 60, weekly: 26, monthly: 24, yearly: 5)
            case .short: Retention(hourly: 0, daily: 7, weekly: 4, monthly: 6, yearly: 0)
            case .custom: nil
            }
        }
    }

    private var retentionBinding: Binding<RetentionPreset> {
        Binding(
            get: { RetentionPreset.allCases.first { $0.retention == c.state.settings.retention } ?? .custom },
            set: { p in if let r = p.retention { c.updateSettings { $0.retention = r } } })
    }

    private var retentionDescription: String {
        let r = c.state.settings.retention
        var parts: [String] = []
        if r.hourly > 0 { parts.append("hourly for \(r.hourly) hours") }
        if r.daily > 0 { parts.append("daily for \(r.daily) days") }
        if r.weekly > 0 { parts.append("weekly for \(r.weekly) weeks") }
        if r.monthly > 0 { parts.append("monthly for \(r.monthly) months") }
        if r.yearly > 0 { parts.append("yearly for \(r.yearly) years") }
        return "Keeps backups " + parts.joined(separator: ", ") + ". Older ones are removed to free space."
    }
}
