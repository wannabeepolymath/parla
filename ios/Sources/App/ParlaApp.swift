import SwiftUI

@main struct ParlaApp: App {
    @StateObject private var coordinator = DictationCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(coordinator).environmentObject(coordinator.library)
                .environmentObject(coordinator.settings).environmentObject(coordinator.models)
                .preferredColorScheme(.light)
                .onOpenURL { url in
                    guard url.scheme == "parla" else { return }
                    if url.host == "notes" { coordinator.route = "Scratchpad" }
                    else if url.host == "settings" { coordinator.route = "Settings" }
                    // Deep links never activate a microphone; the foreground user confirms Start.
                }
                .onChange(of: scenePhase) { _, phase in if phase == .active { coordinator.foreground() } }
        }
    }
}
