import AVFoundation
import BallTracking
import SwiftUI

/// Draws the tracked ball and a short trail over a `VideoPlayer`, following the
/// player's current time every display frame. Assumes aspect-fit video, which is
/// what `VideoPlayer` renders, so the video rect is `AVMakeRect` over our bounds.
struct BallTrackOverlay: View {
    let track: BallTrack
    let player: AVPlayer

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                let time = player.currentTime().seconds
                guard time.isFinite else { return }
                let videoRect = AVMakeRect(aspectRatio: track.displaySize, insideRect: CGRect(origin: .zero, size: size))
                let geometry = OverlayGeometry(videoRect: videoRect)

                let trail = track.trail(endingAt: time, duration: 0.4)
                if trail.count > 1 {
                    var path = Path()
                    path.move(to: geometry.point(forNormalized: trail[0]))
                    for point in trail.dropFirst() {
                        path.addLine(to: geometry.point(forNormalized: point))
                    }
                    context.stroke(path, with: .color(.white.opacity(0.8)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

                guard let frame = track.frame(at: time), frame.isVisible, let position = frame.position else { return }
                let center = geometry.point(forNormalized: position)
                let radius = max(8, geometry.length(forNormalizedWidthFraction: frame.radius ?? 0.005) * 2.5)
                let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                let color: Color = frame.state == .tracking ? .green : .orange
                context.stroke(ring, with: .color(color), lineWidth: 2.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
