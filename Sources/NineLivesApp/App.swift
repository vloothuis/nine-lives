import SwiftUI
import AppKit
import NineLivesCore

enum Pane: String, CaseIterable, Identifiable {
    case overview, restore, disks, activity, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .restore: "Restore"
        case .disks: "Disks"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "heart.text.square"
        case .restore: "clock.arrow.circlepath"
        case .disks: "externaldrive"
        case .activity: "list.bullet.rectangle"
        case .settings: "gearshape"
        }
    }
}

@MainActor @Observable
final class Navigation {
    var pane: Pane = .overview
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?
    var launchedAtLogin = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow?() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct NineLivesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var coordinator = BackupCoordinator()
    @State private var navigation = Navigation()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(coordinator)
                .environment(navigation)
        } label: {
            MenuBarLabel(delegate: delegate)
                .environment(coordinator)
        }
        .menuBarExtraStyle(.window)

        Window("Nine Lives", id: "main") {
            MainWindow()
                .environment(coordinator)
                .environment(navigation)
                .frame(minWidth: 780, minHeight: 520)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                }
                .onDisappear {
                    DispatchQueue.main.async {
                        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                            NSApp.setActivationPolicy(.accessory)
                        }
                    }
                }
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 900, height: 620)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Nine Lives") { AboutPanel.show() }
            }
        }
    }
}

struct MenuBarLabel: View {
    @Environment(BackupCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    let delegate: AppDelegate

    var symbol: String {
        switch coordinator.status {
        case .needsSetup: "externaldrive.badge.plus"
        case .running: "arrow.triangle.2.circlepath"
        case .ok: "externaldrive.badge.checkmark"
        case .warning, .error: "externaldrive.badge.exclamationmark"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .task {
                delegate.openMainWindow = { openWindow(id: "main") }
                coordinator.start()
                if !coordinator.state.onboardingComplete || !delegate.launchedAtLogin {
                    openWindow(id: "main")
                }
            }
    }
}
