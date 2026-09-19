import SwiftUI

/// Top-level tabs. The tab bar is hidden while recording so the whole screen
/// stays a tap target.
struct RootView: View {
    @Environment(AppContainer.self) private var container
    @State private var selectedTab: Tab = .record

    enum Tab: Hashable {
        case record, library, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            RecordScreen()
                .toolbar(container.sessionState.isRecording ? .hidden : .visible, for: .tabBar)
                .tabItem { Label("Record", systemImage: "record.circle") }
                .tag(Tab.record)

            LibraryScreen()
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                .tag(Tab.library)

            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onChange(of: container.sessionState.isRecording) { _, isRecording in
            if isRecording { selectedTab = .record }
        }
    }
}
