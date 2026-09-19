import SwiftUI
import UIKit

/// Top-level tabs. The tab bar sits at the top so hiding it while recording
/// does not move the record button at the bottom of the viewfinder.
struct RootView: View {
    @Environment(AppContainer.self) private var container
    @State private var selectedTab: Tab = .record

    enum Tab: String, CaseIterable, Hashable {
        case record, library, settings

        var title: String {
            switch self {
            case .record: "Record"
            case .library: "Library"
            case .settings: "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .record: "record.circle"
            case .library: "square.grid.2x2"
            case .settings: "gearshape"
            }
        }
    }

    var body: some View {
        ZStack {
            RecordScreen()
                .opacity(selectedTab == .record ? 1 : 0)
                .allowsHitTesting(selectedTab == .record)

            if selectedTab == .library {
                LibraryScreen()
                    .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            } else if selectedTab == .settings {
                SettingsScreen()
                    .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            }
        }
        .overlay(alignment: .top) {
            if !container.sessionState.isRecording {
                topTabBar
                    .padding(.top, 8)
            }
        }
        .statusBarHidden(selectedTab == .record)
        .onAppear { applyOrientation(for: selectedTab) }
        .onChange(of: selectedTab) { _, tab in
            applyOrientation(for: tab)
        }
        .onChange(of: container.sessionState.isRecording) { _, isRecording in
            if isRecording {
                selectedTab = .record
            } else {
                showLibraryIfRequested()
            }
            applyOrientation(for: isRecording ? .record : selectedTab)
        }
        .onChange(of: container.pendingLibraryClip) { _, _ in
            showLibraryIfRequested()
        }
    }

    private var usesCameraChrome: Bool { selectedTab == .record }

    private var topTabBar: some View {
        HStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                tabRow(iconOnly: false)
                tabRow(iconOnly: true)
            }
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(usesCameraChrome ? 0.28 : 0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    private func tabRow(iconOnly: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases, id: \.self) { tab in
                tabButton(tab, iconOnly: iconOnly)
            }
        }
    }

    private func tabButton(_ tab: Tab, iconOnly: Bool) -> some View {
        let selected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            Group {
                if iconOnly {
                    Label(tab.title, systemImage: tab.systemImage)
                        .labelStyle(.iconOnly)
                } else {
                    Label(tab.title, systemImage: tab.systemImage)
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, iconOnly ? 12 : 14)
            .padding(.vertical, 8)
            .background(tabFill(selected: selected), in: Capsule())
            .foregroundStyle(tabLabel(selected: selected))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tabFill(selected: Bool) -> Color {
        if usesCameraChrome {
            return selected ? .white : .white.opacity(0.18)
        }
        return selected ? .primary : .primary.opacity(0.12)
    }

    private func tabLabel(selected: Bool) -> Color {
        if usesCameraChrome {
            return selected ? .black : .white
        }
        return selected ? Color(uiColor: .systemBackground) : .primary
    }

    /// Library is created only when selected; wait until capture is not live so
    /// the recording-tab lock does not yank us back to Record.
    private func showLibraryIfRequested() {
        guard container.pendingLibraryClip != nil else { return }
        guard !container.sessionState.isRecording else { return }
        selectedTab = .library
    }

    private func applyOrientation(for tab: Tab) {
        if tab == .record {
            InterfaceOrientationLock.apply(.landscape, forcing: .landscape)
        } else {
            InterfaceOrientationLock.apply(.allButUpsideDown)
        }
    }
}

// MARK: - Shared screen metrics

/// Insets screens apply to their own content (`.padding`), not to the scroll
/// view or safe area, so backgrounds and scroll indicators run edge to edge.
enum ScreenMetrics {
    static let horizontal: CGFloat = 20
    /// Clears the floating tab pill; scroll views still draw behind it.
    static let top: CGFloat = 60
}

/// App-wide semantic colors. Adopt in new UI; existing screens can migrate later.
enum AppPalette {
    static let accent = Color(red: 0.20, green: 0.48, blue: 0.96)
    static let confirm = Color(red: 0.18, green: 0.67, blue: 0.39)
    static let danger = Color(red: 0.90, green: 0.22, blue: 0.24)
    static let onFill = Color.white
}
