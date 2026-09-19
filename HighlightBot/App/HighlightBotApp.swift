import HighlightCore
import SwiftData
import SwiftUI
import os

/// App entry point. Owns the single `AppContainer` and injects it into the view tree.
@main
struct HighlightBotApp: App {
    @State private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                .modelContainer(container.modelContainer)
                .task { await container.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Capture resume is driven by the pipeline via CaptureEvent; nothing to do here.
                Log.ui.info("Scene became active")
                container.permissions.refresh()
            case .background:
                Log.ui.info("Scene entered background; capture will be interrupted by the system")
            case .inactive:
                Log.ui.debug("Scene inactive")
            @unknown default:
                break
            }
        }
    }
}
