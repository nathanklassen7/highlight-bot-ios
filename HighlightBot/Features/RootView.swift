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
            if isRecording { selectedTab = .record }
            applyOrientation(for: isRecording ? .record : selectedTab)
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

    private func applyOrientation(for tab: Tab) {
        if tab == .record {
            InterfaceOrientationLock.apply(.landscape, forcing: .landscape)
        } else {
            InterfaceOrientationLock.apply(.allButUpsideDown)
        }
    }
}

// MARK: - Shared screen padding

/// One set of insets for tab chrome, Library, Settings, and the clip player.
enum ScreenMetrics {
    static let horizontal: CGFloat = 32
    /// Clears the floating tab pill; scroll views still draw behind it.
    static let top: CGFloat = 60
}

private struct ScreenPaddingModifier: ViewModifier {
    var edges: Edge.Set

    func body(content: Content) -> some View {
        content
            .contentMargins(.leading, leading, for: .scrollContent)
            .contentMargins(.trailing, trailing, for: .scrollContent)
            .contentMargins(.top, top, for: .scrollContent)
            .padding(
                EdgeInsets(
                    top: 0,
                    leading: leading,
                    bottom: 0,
                    trailing: trailing
                )
            )
    }

    private var leading: CGFloat { edges.contains(.leading) ? ScreenMetrics.horizontal : 0 }
    private var trailing: CGFloat { edges.contains(.trailing) ? ScreenMetrics.horizontal : 0 }
    private var top: CGFloat { edges.contains(.top) ? ScreenMetrics.top : 0 }
}

extension View {
    /// Insets a screen using `ScreenMetrics` so portrait rounding and the tab bar
    /// leave the same gap everywhere.
    func screenPadding(_ edges: Edge.Set = [.horizontal, .top]) -> some View {
        modifier(ScreenPaddingModifier(edges: edges))
    }
}
