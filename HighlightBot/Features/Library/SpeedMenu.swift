import SwiftUI

/// The playback-speed picker shared by the player (playback rate) and the
/// editor (slow-mo rate): a compact tortoise-and-percent trigger in a bar,
/// and a menu that floats above the bar so the bar's width never changes.
///
/// Usage: put `SpeedMenuTrigger` in the bar, then attach
/// `.speedMenuOverlay(...)` to an ancestor that spans the area the menu may
/// float over. The trigger publishes its bounds through `SpeedMenuAnchorKey`;
/// the overlay reads them to sit just above the trigger, left-aligned.
enum SpeedMenu {
    /// Rates the player offers, fastest first.
    static let playbackRates: [Float] = [1.0, 0.5, 0.25, 0.15]

    static func percentLabel(for rate: Float) -> String {
        "\(Int((rate * 100).rounded()))%"
    }
}

/// Bounds of the speed trigger, used to anchor the menu above its bar.
struct SpeedMenuAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Compact trigger showing the current rate. Toggles `isExpanded`.
struct SpeedMenuTrigger: View {
    let rate: Float
    @Binding var isExpanded: Bool
    /// Spoken name for the setting, e.g. "playback speeds" or "slow-mo speeds".
    var accessibilityNoun = "playback speeds"

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tortoise.fill")
                Text(SpeedMenu.percentLabel(for: rate))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isExpanded ? Color.yellow : Color.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide \(accessibilityNoun)" : "Show \(accessibilityNoun)")
        .accessibilityValue(SpeedMenu.percentLabel(for: rate))
        .anchorPreference(key: SpeedMenuAnchorKey.self, value: .bounds) { $0 }
    }
}

/// The list of rates. Selecting one calls `onSelect` and closes the menu.
struct SpeedMenuList: View {
    let rates: [Float]
    let selection: Float
    let onSelect: (Float) -> Void
    var accessibilityNoun = "Playback speed"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rates, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    onSelect(option)
                } label: {
                    HStack(spacing: 10) {
                        Text(SpeedMenu.percentLabel(for: option))
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(isSelected ? Color.yellow : Color.white)
                            .frame(minWidth: 36, alignment: .leading)
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.yellow)
                            .opacity(isSelected ? 1 : 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(accessibilityNoun) \(SpeedMenu.percentLabel(for: option))")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
        .fixedSize()
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    /// Floats a `SpeedMenuList` just above the `SpeedMenuTrigger` inside this
    /// view while `isExpanded` is true. Attach to an ancestor of the trigger
    /// that covers the space the menu should be allowed to overlap.
    func speedMenuOverlay(
        isExpanded: Binding<Bool>,
        rates: [Float],
        selection: Float,
        accessibilityNoun: String = "Playback speed",
        onSelect: @escaping (Float) -> Void
    ) -> some View {
        overlayPreferenceValue(SpeedMenuAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if isExpanded.wrappedValue, let anchor {
                    let trigger = proxy[anchor]
                    SpeedMenuList(rates: rates, selection: selection, onSelect: { rate in
                        onSelect(rate)
                        isExpanded.wrappedValue = false
                    }, accessibilityNoun: accessibilityNoun)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        // Trigger top is inside the bar's 10pt vertical padding; add an 8pt gap.
                        .padding(.leading, trigger.minX)
                        .padding(.bottom, proxy.size.height - trigger.minY + 18)
                        .transition(.scale(scale: 0.9, anchor: .bottomLeading).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isExpanded.wrappedValue)
        }
    }
}
