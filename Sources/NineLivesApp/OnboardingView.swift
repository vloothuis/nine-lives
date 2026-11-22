import SwiftUI
import NineLivesCore

struct OnboardingView: View {
    @Environment(BackupCoordinator.self) private var c
    @Environment(Navigation.self) private var nav

    enum Page: Int, CaseIterable { case welcome, access, disk, options }

    @State private var page = Page.welcome
    @State private var hasAccess = Permissions.hasFullDiskAccess()
    @State private var launchAtLogin = true
    @State private var notifications = true
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .welcome: welcome
                case .access: access
                case .disk: AddDiskFlow(onDone: { page = .options })
                case .options: options
                }
            }
            .frame(maxWidth: 520, maxHeight: .infinity)
            .padding(.horizontal, 20)

            HStack(spacing: 6) {
                ForEach(Page.allCases, id: \.rawValue) { p in
                    Circle().fill(p == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                }
            }.padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(poll) { _ in hasAccess = Permissions.hasFullDiskAccess() }
    }

    private func big(_ symbol: String, color: Color = .accentColor) -> some View {
        Image(systemName: symbol).font(.system(size: 64)).foregroundStyle(color).padding(.bottom, 8)
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Spacer()
            big("heart.text.square.fill")
            Text("Welcome to Nine Lives").font(.largeTitle.weight(.bold))
            Text("Plug in a USB disk and your Mac is backed up. If something goes wrong, you get your files back.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if !c.engineAvailable { MissingEngineBanner() }
            Spacer()
            Button("Get Started") { page = .access }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            Spacer().frame(height: 24)
        }
    }

    private var access: some View {
        VStack(spacing: 14) {
            Spacer()
            big(hasAccess ? "checkmark.shield.fill" : "lock.shield.fill", color: hasAccess ? .green : .accentColor)
            Text("Let Nine Lives read your files").font(.title.weight(.bold))
            Text("macOS protects Mail, Photos, Safari and other private data. To include them in your backup, give Nine Lives Full Disk Access.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if hasAccess {
                Label("Full Disk Access is on", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("Open System Settings, then turn on Nine Lives under Privacy & Security, Full Disk Access.")
                    .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Open System Settings") { Permissions.openFullDiskAccessSettings() }.controlSize(.large)
            }
            Spacer()
            HStack {
                Button("Back") { page = .welcome }
                Spacer()
                Button(hasAccess ? "Continue" : "Continue Without") { page = .disk }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(.bottom, 24)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            big("checkmark.circle.fill", color: .green).frame(maxWidth: .infinity)
            Text("Your disk is ready").font(.title.weight(.bold)).frame(maxWidth: .infinity)
            Text("Nine Lives backs up while the disk is connected and tells you when it is safe to unplug.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            Toggle("Open Nine Lives when I log in", isOn: $launchAtLogin)
            Toggle("Notify me when a backup finishes", isOn: $notifications)
            Toggle("Eject the disk after a backup that starts when I plug it in", isOn: Binding(
                get: { c.state.settings.ejectAfterPlugIn }, set: { v in c.updateSettings { $0.ejectAfterPlugIn = v } }))
            Spacer()
            HStack {
                Spacer()
                Button("Start First Backup") { finish() }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }.padding(.bottom, 24)
        }
    }

    private func finish() {
        try? LaunchAtLogin.set(launchAtLogin)
        c.updateSettings { $0.notifyOnSuccess = notifications }
        if notifications { Task { _ = await c.requestNotificationPermission() } }
        c.completeOnboarding()
        nav.pane = .overview
        if let disk = c.state.disks.first { c.startBackup(diskID: disk.id, trigger: .manual) }
    }
}
