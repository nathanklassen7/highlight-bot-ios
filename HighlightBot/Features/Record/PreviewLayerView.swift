import AVFoundation
import HighlightCore
import SwiftUI
import UIKit

/// Hosts the capture source's preview `CALayer` (an `AVCaptureVideoPreviewLayer`
/// on device, an `AVSampleBufferDisplayLayer` for file replay) and keeps it
/// sized to the screen. The preview sits in a subview whose transform cancels
/// interface rotation (Apple QA1890) so only Record chrome rotates.
struct PreviewLayerView: UIViewControllerRepresentable {
    let source: any CaptureSource

    func makeUIViewController(context: Context) -> PreviewHostController {
        let controller = PreviewHostController()
        let layer = source.makePreviewLayer()
        if let preview = layer as? AVCaptureVideoPreviewLayer {
            preview.videoGravity = .resizeAspectFill
        } else if let display = layer as? AVSampleBufferDisplayLayer {
            display.videoGravity = .resizeAspect
        }
        controller.hostedLayer = layer
        return controller
    }

    func updateUIViewController(_ controller: PreviewHostController, context: Context) {}
}

/// Owns the non-rotating preview subview. The controller's own view still
/// follows the interface so SwiftUI can size it; only `previewView` is locked.
final class PreviewHostController: UIViewController {
    private let previewView = LayerHostView()

    var hostedLayer: CALayer? {
        get { previewView.hostedLayer }
        set { previewView.hostedLayer = newValue }
    }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        previewView.backgroundColor = .black
        previewView.isUserInteractionEnabled = false
        view.addSubview(previewView)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        layoutPreviewView()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self else { return }
            let deltaAngle = Double(atan2(coordinator.targetTransform.b, coordinator.targetTransform.a))
            let current = self.previewRotationRadians()
            let next = PreviewOrientationLock.nextAnimatedRotation(
                current: current,
                interfaceDelta: deltaAngle
            )
            self.previewView.layer.setValue(next, forKeyPath: "transform.rotation.z")
            self.layoutPreviewView()
        }, completion: { [weak self] _ in
            guard let self else { return }
            // Keep the animated inverse; do not replace it with a heading map.
            // landscapeLeft/Right window signs disagree with UIKit, and that
            // overwrite was flipping the viewfinder 180° on land.
            let landed = self.previewRotationRadians()
            self.previewView.transform = Self.integralized(
                CGAffineTransform(rotationAngle: CGFloat(landed))
            )
            self.layoutPreviewView()
        })
    }

    private func previewRotationRadians() -> Double {
        Double(
            (previewView.layer.value(forKeyPath: "transform.rotation.z") as? CGFloat)
                ?? atan2(previewView.transform.b, previewView.transform.a)
        )
    }

    private func layoutPreviewView() {
        let parent = view.bounds.size
        let size = PreviewOrientationLock.coveringSize(
            parentWidth: parent.width,
            parentHeight: parent.height,
            rotationRadians: previewRotationRadians()
        )
        previewView.bounds = CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height))
        previewView.center = CGPoint(x: parent.width / 2, y: parent.height / 2)
    }

    private static func integralized(_ transform: CGAffineTransform) -> CGAffineTransform {
        var transform = transform
        transform.a = transform.a.rounded()
        transform.b = transform.b.rounded()
        transform.c = transform.c.rounded()
        transform.d = transform.d.rounded()
        return transform
    }
}

/// A `UIView` whose only job is to keep one sublayer filling its bounds.
final class LayerHostView: UIView {
    var hostedLayer: CALayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let hostedLayer {
                layer.addSublayer(hostedLayer)
                setNeedsLayout()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedLayer?.frame = layer.bounds
        CATransaction.commit()
    }
}
