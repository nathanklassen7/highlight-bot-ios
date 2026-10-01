import HighlightCore
import SwiftUI
import UIKit

/// Transparent touch layer over the editor preview. Pinch zooms around the
/// midpoint of the fingers and pans as that midpoint moves, like Photos; one
/// finger pans; a tap is forwarded. UIKit recognizers are used because
/// SwiftUI's `MagnifyGesture` only reports where a pinch started.
struct CropGestureBridge: UIViewRepresentable {
    var crop: ClipCrop
    /// Size of the video's frame, centred in this view.
    var fitSize: CGSize
    var onCropChange: (ClipCrop) -> Void
    var onAdjustingChange: (Bool) -> Void
    var onTap: () -> Void

    func makeCoordinator() -> CropGestureController {
        CropGestureController()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let controller = context.coordinator
        controller.fitSize = fitSize
        controller.onCropChange = onCropChange
        controller.onAdjustingChange = onAdjustingChange
        controller.onTap = onTap
        if !controller.isAdjusting {
            controller.crop = crop
        }
    }
}

@MainActor
final class CropGestureController: NSObject, UIGestureRecognizerDelegate {
    /// Working copy, so back-to-back touch events build on each other
    /// without waiting for SwiftUI to round-trip the state.
    var crop = ClipCrop.identity
    var fitSize: CGSize = .zero
    var onCropChange: ((ClipCrop) -> Void)?
    var onAdjustingChange: ((Bool) -> Void)?
    var onTap: (() -> Void)?

    private(set) var isAdjusting = false
    private var pan: UIPanGestureRecognizer?
    private var pinch: UIPinchGestureRecognizer?
    /// Last applied finger location for each recognizer. Reset whenever the
    /// touch count changes, since the midpoint jumps when a finger lands or
    /// lifts.
    private var panAnchor: (point: CGPoint, touches: Int)?
    private var pinchAnchor: (point: CGPoint, scale: CGFloat, touches: Int)?

    func install(on view: UIView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        pan.delegate = self
        pinch.delegate = self
        for recognizer in [pan, pinch, tap] as [UIGestureRecognizer] {
            view.addGestureRecognizer(recognizer)
        }
        self.pan = pan
        self.pinch = pinch
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        (gestureRecognizer === pan && otherGestureRecognizer === pinch)
            || (gestureRecognizer === pinch && otherGestureRecognizer === pan)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        if gesture.state == .ended {
            onTap?()
        }
    }

    /// One finger only; with two or more the pinch drives both zoom and pan.
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            let point = gesture.location(in: gesture.view)
            let touches = gesture.numberOfTouches
            if touches == 1, pinchAnchor == nil, let anchor = panAnchor, anchor.touches == 1 {
                apply(from: anchor.point, to: point, scaleFactor: 1)
            }
            panAnchor = (point, touches)
        default:
            panAnchor = nil
        }
        updateAdjusting()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            let touches = gesture.numberOfTouches
            guard touches >= 2 else {
                pinchAnchor = nil
                break
            }
            let point = gesture.location(in: gesture.view)
            if let anchor = pinchAnchor, anchor.touches == touches, anchor.scale > 0 {
                apply(from: anchor.point, to: point, scaleFactor: gesture.scale / anchor.scale)
            }
            pinchAnchor = (point, gesture.scale, touches)
        default:
            pinchAnchor = nil
        }
        updateAdjusting()
    }

    private func apply(from start: CGPoint, to end: CGPoint, scaleFactor: CGFloat) {
        guard let view = pan?.view, fitSize.width > 0, fitSize.height > 0 else { return }
        let originX = (view.bounds.width - fitSize.width) / 2
        let originY = (view.bounds.height - fitSize.height) / 2
        let next = crop.pinched(
            to: crop.clamped().scale * scaleFactor,
            fromX: (start.x - originX) / fitSize.width,
            fromY: (start.y - originY) / fitSize.height,
            toX: (end.x - originX) / fitSize.width,
            toY: (end.y - originY) / fitSize.height
        )
        guard next != crop else { return }
        crop = next
        onCropChange?(next)
    }

    private func updateAdjusting() {
        let active = [pan, pinch].contains { recognizer in
            recognizer?.state == .began || recognizer?.state == .changed
        }
        guard active != isAdjusting else { return }
        isAdjusting = active
        onAdjustingChange?(active)
    }
}
