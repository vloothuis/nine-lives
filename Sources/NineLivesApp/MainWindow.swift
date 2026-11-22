import SwiftUI
import NineLivesCore

struct MainWindow: View {
    @Environment(BackupCoordinator.self) private var c
    @Environment(Navigation.self) private var nav

    var body: some View {
        if !c.state.onboardingComplete {
            OnboardingView()
        } else {
            @Bindable var nav = nav
            NavigationSplitView {
                List(Pane.allCases, selection: $nav.pane) { pane in
                    Label(pane.title, systemImage: pane.symbol).tag(pane)
                }
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            } detail: {
                switch nav.pane {
                case .overview: OverviewView()
                case .restore: RestoreView()
                case .disks: DisksView()
                case .activity: ActivityView()
                case .settings: SettingsView()
                }
            }
            .overlay(alignment: .bottom) {
                if !c.engineAvailable { MissingEngineBanner() }
            }
        }
    }
}

struct MissingEngineBanner: View {
    var body: some View {
        Label("The backup engine (restic) is missing. Reinstall Nine Lives or choose restic in Settings.", systemImage: "exclamationmark.triangle.fill")
            .padding(10)
            .background(.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            .padding()
    }
}
