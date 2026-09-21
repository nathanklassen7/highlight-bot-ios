import AVFoundation
import HighlightCore
import SwiftUI
import UIKit

/// Filmstrip of the clip with draggable start/end handles and a playhead.
/// Times are seconds from the start of the clip. The handles never come closer
/// than `minimumDuration` and never leave `0...duration`.
///
/// An optional slow-mo segment draws inside the kept range with the same kind
/// of handles in green. Its edges stay inside `start...end` and at least
/// `slowMotionMinimumDuration` apart; moving a trim handle past it pushes it
/// along. Green handles sit above yellow ones, so where the two coincide the
/// slow-mo edge moves first and uncovers the trim handle.
///
/// Dragging inside the selected range scrubs the playhead; dragging a handle
/// moves that edge. `onEditingChanged` brackets both so the owner can pause
/// playback and stop its time observer from fighting the drag.
struct TrimRangeBar: View {
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    @Binding var slowMotion: SlowMotionSegment?
    let playhead: Double
    let minimumDuration: Double
    let slowMotionMinimumDuration: Double
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
        case start, end, slowStart, slowEnd

        var isSlowMotion: Bool { self == .slowStart || self == .slowEnd }
        var isLeading: Bool { self == .start || self == .slowStart }
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

                if let slowMotion {
                    let slowStartX = x(for: slowMotion.start, stripWidth: stripWidth)
                    let slowEndX = x(for: slowMotion.end, stripWidth: stripWidth)

                    // Tint the stretch that will be slowed.
                    Color.green.opacity(0.28)
                        .frame(width: max(slowEndX - slowStartX, 0), height: height)
                        .offset(x: slowStartX)
                        .allowsHitTesting(false)

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.green, lineWidth: borderWidth)
                        .frame(width: slowEndX - slowStartX + handleWidth * 2, height: height)
                        .offset(x: slowStartX - handleWidth)
                        .allowsHitTesting(false)
                }

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

                if let slowMotion {
                    handle(.slowStart, height: height)
                        .offset(x: x(for: slowMotion.start, stripWidth: stripWidth) - handleWidth)
                        .gesture(handleGesture(.slowStart, stripWidth: stripWidth))
                    handle(.slowEnd, height: height)
                        .offset(x: x(for: slowMotion.end, stripWidth: stripWidth))
                        .gesture(handleGesture(.slowEnd, stripWidth: stripWidth))
                }
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
        let radii = edge.isLeading
            ? RectangleCornerRadii(topLeading: cornerRadius, bottomLeading: cornerRadius)
            : RectangleCornerRadii(bottomTrailing: cornerRadius, topTrailing: cornerRadius)
        let value = time(of: edge)
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
            .fill(edge.isSlowMotion ? Color.green : Color.yellow)
            .overlay {
                Image(systemName: edge.isLeading ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.black.opacity(0.7))
            }
            .frame(width: handleWidth, height: height)
            // Generous hit area; the visible handle stays narrow.
            .contentShape(Rectangle().inset(by: -10))
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel(for: edge))
            .accessibilityValue(Self.timeText(value))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? accessibilityStep : -accessibilityStep
                set(edge, to: value + delta)
            }
    }

    private func accessibilityLabel(for edge: Edge) -> String {
        switch edge {
        case .start: "Trim start"
        case .end: "Trim end"
        case .slowStart: "Slow-mo start"
        case .slowEnd: "Slow-mo end"
        }
    }

    // MARK: - Geometry

    private func x(for time: Double, stripWidth: CGFloat) -> CGFloat {
        guard duration > 0 else { return handleWidth }
        let fraction = min(max(time / duration, 0), 1)
        return handleWidth + CGFloat(fraction) * stripWidth
    }

    private func time(of edge: Edge) -> Double {
        switch edge {
        case .start: start
        case .end: end
        case .slowStart: slowMotion?.start ?? start
        case .slowEnd: slowMotion?.end ?? end
        }
    }

    private func set(_ edge: Edge, to value: Double) {
        switch edge {
        case .start:
            start = min(max(value, 0), end - minimumDuration)
            slowMotion = slowMotion?.clamped(to: start, end, minimumDuration: slowMotionMinimumDuration)
        case .end:
            end = max(min(value, duration), start + minimumDuration)
            slowMotion = slowMotion?.clamped(to: start, end, minimumDuration: slowMotionMinimumDuration)
        case .slowStart:
            guard var segment = slowMotion else { return }
            segment.start = min(max(value, start), segment.end - slowMotionMinimumDuration)
            slowMotion = segment
        case .slowEnd:
            guard var segment = slowMotion else { return }
            segment.end = max(min(value, end), segment.start + slowMotionMinimumDuration)
            slowMotion = segment
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
                    origin = time(of: edge)
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
