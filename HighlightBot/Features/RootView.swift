import SwiftUI
import UIKit

/// Top-level tabs. The tab bar sits at the top so hiding it while recording
/// does not move the record button at the bottom of the viewfinder.
struct RootView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var selectedTab: Tab = .record

    /// Portrait has no leading/trailing safe area, so rounded screen corners
    /// clip edge-hugging chrome. Landscape already has notch/home-indicator inset.
    private var portraitGutter: CGFloat {
        verticalSizeClass == .regular ? 8 : 0
    }

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
        .safeAreaInset(edge: .top, spacing: 0) {
            if !container.sessionState.isRecording {
                topTabBar
            }
        }
        .safeAreaInset(edge: .leading, spacing: 0) {
            if portraitGutter > 0 { Color.clear.frame(width: portraitGutter) }
        }
        .safeAreaInset(edge: .trailing, spacing: 0) {
            if portraitGutter > 0 { Color.clear.frame(width: portraitGutter) }
        }
        .statusBarHidden(selectedTab == .record)
        .onAppear { applyOrientation(for: selectedTab) }
        .onChange(of: selectedTab) { _, tab in
            applyOrientation(for: tab)
        }
        .onChange(of: container.sessionState.isRecording) { _, isRecording in
            if isRecording { selectedTab = .record }
            applyOrientation(for: isRecording ? .record : selectedTab)
        }
    }

    private var usesCameraChrome: Bool { selectedTab == .record }

    private var topTabBar: some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                tabRow(iconOnly: false)
                tabRow(iconOnly: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .safeAreaPadding(.horizontal)
        .frame(maxWidth: .infinity)
        .background(usesCameraChrome ? Color.clear : Color(uiColor: .systemBackground))
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

    private func applyOrientation(for tab: Tab) {
        if tab == .record {
            InterfaceOrientationLock.apply(.landscape, forcing: .landscape)
        } else {
            InterfaceOrientationLock.apply(.allButUpsideDown)
        }
    }
}
