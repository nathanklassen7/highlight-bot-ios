import AVFoundation
import SwiftUI
import UIKit

/// Renders `player` with aspect-fit video and no system playback controls.
/// Shared by the clip player and the trim editor.
///
/// The view is transparent: when the layer has no frame to show (before the
/// first frame, or across an item swap) whatever sits behind it shows through.
/// Hosts put a black backdrop or a poster thumbnail there.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// Mirrors `AVPlayerLayer.isReadyForDisplay`. Optional so the trim editor
    /// can ignore it; delivered on the main thread.
    var onReadyForDisplayChange: ((Bool) -> Void)? = nil

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView(player: player)
        view.onReadyForDisplayChange = onReadyForDisplayChange
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
        uiView.onReadyForDisplayChange = onReadyForDisplayChange
    }
}

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var onReadyForDisplayChange: ((Bool) -> Void)?
    private var readyObservation: NSKeyValueObservation?

    init(player: AVPlayer) {
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        // AVFoundation may flip this off the main thread.
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async {
                self?.onReadyForDisplayChange?(ready)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
