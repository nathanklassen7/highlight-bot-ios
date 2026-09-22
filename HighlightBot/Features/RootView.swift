import SwiftUI
import UIKit

/// Top-level screens, switched by a floating pill centred at the top. The
/// pill sits at the top so hiding it during a session does not move the
/// shutter at the bottom of the viewfinder. `RecordScreen` stays mounted
/// underneath the other tabs so the viewfinder never has to restart.
enum AppTab: String, CaseIterable, Hashable {
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

struct RootView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        let selectedTab = container.selectedTab
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
            if showsTabBar {
                topTabBar
                    .padding(.top, 8)
            }
        }
        .statusBarHidden(selectedTab == .record)
        .onAppear { applyOrientation(recording: container.sessionState.isRecording) }
        .onChange(of: container.selectedTab) { _, _ in
            applyOrientation(recording: container.sessionState.isRecording)
        }
        .onChange(of: container.sessionState.isRecording) { _, isRecording in
            if isRecording {
                container.selectedTab = .record
            } else if container.libraryRequested {
                // Asked for mid-session; safe to show now that capture is down.
                container.libraryRequested = false
                container.selectedTab = .library
            }
            applyOrientation(recording: isRecording)
        }
    }

    private var usesCameraChrome: Bool { container.selectedTab == .record }

    /// The pill shares the top strip's centre with the session status on the
    /// Record screen, so it only shows there while nothing is live.
    private var showsTabBar: Bool {
        !usesCameraChrome || container.sessionState == .idle
    }

    /// Icons alone on the Record screen, where the top strip is already busy;
    /// icons and names elsewhere. One row whose titles come and go, rather
    /// than two rows swapped, so the pill animates between the two widths.
    private var topTabBar: some View {
        let iconOnly = usesCameraChrome
        return HStack(spacing: 6) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                tabButton(tab, iconOnly: iconOnly)
            }
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(iconOnly ? 0.28 : 0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .animation(.snappy(duration: 0.3), value: iconOnly)
    }

    private func tabButton(_ tab: AppTab, iconOnly: Bool) -> some View {
        let selected = container.selectedTab == tab
        return Button {
            container.selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.systemImage)
                if !iconOnly {
                    Text(tab.title)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
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

    /// Recording pins the interface to wherever the phone already is. The
    /// writer's transform is stamped once per session, so a rotation mid-clip
    /// could not reach the file; freezing the UI keeps the two honest.
    private func applyOrientation(recording: Bool) {
        guard recording else {
            InterfaceOrientationLock.apply(.allButUpsideDown)
            return
        }
        InterfaceOrientationLock.apply(Self.currentOrientationMask())
    }

    /// Falls back to the unrestricted mask when no scene is up yet, so a
    /// missing scene cannot pin the app to a guess.
    private static func currentOrientationMask() -> UIInterfaceOrientationMask {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        switch scene?.interfaceOrientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .allButUpsideDown
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
