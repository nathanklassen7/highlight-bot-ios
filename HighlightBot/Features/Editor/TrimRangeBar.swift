import AVFoundation
import SwiftUI
import UIKit

/// Filmstrip of the clip with draggable start/end handles and a playhead.
/// Times are seconds from the start of the clip. The handles never come closer
/// than `minimumDuration` and never leave `0...duration`.
///
/// Dragging inside the selected range scrubs the playhead; dragging a handle
/// moves that edge. `onEditingChanged` brackets both so the owner can pause
/// playback and stop its time observer from fighting the drag.
struct TrimRangeBar: View {
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    let playhead: Double
    let minimumDuration: Double
    let frames: [UIImage]
    let onEditingChanged: (Bool) -> Void
    let onScrub: (Double) -> Void

    @State private var dragOrigin: Double?

    private let handleWidth: CGFloat = 20
    private let cornerRadius: CGFloat = 8
    private let borderWidth: CGFloat = 3
    /// Seconds per VoiceOver increment/decrement on a handle.
    private let accessibilityStep: Double = 0.5

    private enum Edge {
        case start, end
    }

    var body: some View {
        GeometryReader { proxy in
            let stripWidth = max(proxy.size.width - handleWidth * 2, 1)
            let height = proxy.size.height
            let startX = x(for: start, stripWidth: stripWidth)
            let endX = x(for: end, stripWidth: stripWidth)

            ZStack(alignment: .leading) {
                filmstrip(width: stripWidth, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .offset(x: handleWidth)

                // Dim the parts of the clip that will be cut.
                Color.black.opacity(0.6)
                    .frame(width: max(startX - handleWidth, 0), height: height)
                    .offset(x: handleWidth)
                    .allowsHitTesting(false)
                Color.black.opacity(0.6)
                    .frame(width: max(handleWidth + stripWidth - endX, 0), height: height)
                    .offset(x: endX)
                    .allowsHitTesting(false)

                // Scrub area: the kept range between the handles.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: max(endX - startX, 1), height: height)
                    .offset(x: startX)
                    .gesture(scrubGesture(stripWidth: stripWidth))
                    .accessibilityHidden(true)

                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.yellow, lineWidth: borderWidth)
                    .frame(width: endX - startX + handleWidth * 2, height: height)
                    .offset(x: startX - handleWidth)
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white)
                    .frame(width: 3, height: height + 8)
                    .shadow(color: .black.opacity(0.6), radius: 1.5)
                    .offset(x: x(for: playhead, stripWidth: stripWidth) - 1.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                handle(.start, height: height)
                    .offset(x: startX - handleWidth)
                    .gesture(handleGesture(.start, stripWidth: stripWidth))
                handle(.end, height: height)
                    .offset(x: endX)
                    .gesture(handleGesture(.end, stripWidth: stripWidth))
            }
            .coordinateSpace(name: Self.coordinateSpaceName)
        }
        .accessibilityElement(children: .contain)
    }

    /// Scrub locations are read in the bar's own space, not the offset scrub
    /// view's, so they map straight back to time.
    private static let coordinateSpaceName = "TrimRangeBar"

    // MARK: - Pieces

    @ViewBuilder
    private func filmstrip(width: CGFloat, height: CGFloat) -> some View {
        if frames.isEmpty {
            Color.white.opacity(0.12)
                .frame(width: width, height: height)
        } else {
            let cell = width / CGFloat(frames.count)
            HStack(spacing: 0) {
                ForEach(Array(frames.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: cell, height: height)
                        .clipped()
                }
            }
            .frame(width: width, height: height)
        }
    }

    private func handle(_ edge: Edge, height: CGFloat) -> some View {
        let radii = switch edge {
        case .start: RectangleCornerRadii(topLeading: cornerRadius, bottomLeading: cornerRadius)
        case .end: RectangleCornerRadii(bottomTrailing: cornerRadius, topTrailing: cornerRadius)
        }
        let value = edge == .start ? start : end
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
            .fill(Color.yellow)
            .overlay {
                Image(systemName: edge == .start ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.black.opacity(0.7))
            }
            .frame(width: handleWidth, height: height)
            // Generous hit area; the visible handle stays narrow.
            .contentShape(Rectangle().inset(by: -10))
            .accessibilityElement()
            .accessibilityLabel(edge == .start ? "Trim start" : "Trim end")
            .accessibilityValue(Self.timeText(value))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? accessibilityStep : -accessibilityStep
                set(edge, to: value + delta)
            }
    }

    // MARK: - Geometry

    private func x(for time: Double, stripWidth: CGFloat) -> CGFloat {
        guard duration > 0 else { return handleWidth }
        let fraction = min(max(time / duration, 0), 1)
        return handleWidth + CGFloat(fraction) * stripWidth
    }

    private func set(_ edge: Edge, to value: Double) {
        switch edge {
        case .start:
            start = min(max(value, 0), end - minimumDuration)
        case .end:
            end = max(min(value, duration), start + minimumDuration)
        }
    }

    // MARK: - Gestures

    private func handleGesture(_ edge: Edge, stripWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let origin: Double
                if let dragOrigin {
                    origin = dragOrigin
                } else {
                    origin = edge == .start ? start : end
                    dragOrigin = origin
                    onEditingChanged(true)
                }
                let delta = Double(value.translation.width / stripWidth) * duration
                set(edge, to: origin + delta)
            }
            .onEnded { _ in
                dragOrigin = nil
                onEditingChanged(false)
            }
    }

    /// The kept range is the only hit area, but the location is read in the
    /// bar's space and clamped to `start...end` in case the finger runs past
    /// a handle mid-drag.
    private func scrubGesture(stripWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = playhead
                    onEditingChanged(true)
                }
                let time = Double((value.location.x - handleWidth) / stripWidth) * duration
                onScrub(min(max(time, start), end))
            }
            .onEnded { _ in
                dragOrigin = nil
                onEditingChanged(false)
            }
    }

    /// `m:ss.t`, shared with the editor's time labels.
    static func timeText(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds))
            .formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: 1)))
    }
}
