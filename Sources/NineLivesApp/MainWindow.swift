import SwiftUI
import NineLivesCore

struct MainWindow: View {
    @Environment(BackupCoordinator.self) private var c

    var body: some View {
        if !c.state.onboardingComplete {
            OnboardingView()
        } else {
            OverviewView()
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
