import HighlightCore
import SwiftData
import SwiftUI
import UIKit
import os

/// App entry point. Owns the single `AppContainer` and injects it into the view tree.
@main
struct HighlightBotApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

/// Lets Library and Settings rotate to portrait while Record stays landscape.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        InterfaceOrientationLock.mask
    }
}

@MainActor
enum InterfaceOrientationLock {
    static var mask: UIInterfaceOrientationMask = .landscape

    static func apply(_ mask: UIInterfaceOrientationMask, forcing forced: UIInterfaceOrientationMask? = nil) {
        self.mask = mask
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            if let forced {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: forced)) { error in
                    Log.ui.error("Failed to update interface orientation: \(error.localizedDescription)")
                }
            }
        }
    }
}
