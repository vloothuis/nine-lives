import SwiftUI
import AppKit
import NineLivesCore

/// Ids of the app's windows.
enum WindowID {
    static let main = "main"
    static let restore = "restore"
    static let activity = "activity"
}

@MainActor @Observable
final class Navigation {
    /// Disk to show in Restore, set when a backup disk's readme is opened.
    var restoreDiskID: String?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)? { didSet { flushOpenedFiles() } }
    var openFile: ((URL) -> Void)? { didSet { flushOpenedFiles() } }
    var launchedAtLogin = false
    /// Files opened before the app finished setting up.
    private var pendingFiles: [URL] = []

    /// Finder sends the backup disk's `HOW TO RESTORE.txt` here when it is double-clicked.
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingFiles += urls
        flushOpenedFiles()
    }

    private func flushOpenedFiles() {
        guard let openFile, openMainWindow != nil, let last = pendingFiles.last else { return }
        pendingFiles = []
        openFile(last)
    }

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
                .environment(navigation)
        }
        .menuBarExtraStyle(.window)

        Window("Nine Lives", id: WindowID.main) {
            MainWindow()
                .environment(coordinator)
                .environment(navigation)
                .frame(minWidth: 620, minHeight: 480)
                .showsInDock()
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 760, height: 640)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Nine Lives") { AboutPanel.show() }
            }
        }

        Window("Restore Files", id: WindowID.restore) {
            RestoreView()
                .environment(coordinator)
                .environment(navigation)
                .frame(minWidth: 720, minHeight: 460)
                .showsInDock()
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 900, height: 620)

        Window("Activity", id: WindowID.activity) {
            ActivityView()
                .environment(coordinator)
                .frame(minWidth: 640, minHeight: 400)
                .showsInDock()
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 820, height: 560)

        Settings {
            SettingsView()
                .environment(coordinator)
                .frame(width: 560, height: 620)
                .showsInDock()
        }
    }
}

extension View {
    /// Shows the app in the Dock while this window is open. Nine Lives is a menu bar app otherwise.
    func showsInDock() -> some View {
        onAppear {
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
}

struct MenuBarLabel: View {
    @Environment(BackupCoordinator.self) private var coordinator
    @Environment(Navigation.self) private var navigation
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
                delegate.openMainWindow = { openWindow(id: WindowID.main) }
                coordinator.onFullDiskAccessLost = {
                    openWindow(id: WindowID.main)
                    NSApp.activate(ignoringOtherApps: true)
                }
                delegate.openFile = { file in
                    if let disk = coordinator.disk(holding: file) {
                        navigation.restoreDiskID = disk.id
                        openWindow(id: WindowID.restore)
                    } else {
                        openWindow(id: WindowID.main)
                    }
                }
                coordinator.start()
                if !coordinator.state.onboardingComplete || !delegate.launchedAtLogin {
                    openWindow(id: WindowID.main)
                }
            }
    }
}
