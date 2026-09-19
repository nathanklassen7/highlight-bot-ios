import AVFoundation
import SwiftUI
import UIKit

/// Hosts the capture source's preview `CALayer` (an `AVCaptureVideoPreviewLayer`
/// on device, an `AVSampleBufferDisplayLayer` for file replay) and keeps it
/// sized to the view.
struct PreviewLayerView: UIViewRepresentable {
    let source: any CaptureSource

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.backgroundColor = .black
        // Let touches fall through to the SwiftUI gestures on the Record screen.
        view.isUserInteractionEnabled = false
        let layer = source.makePreviewLayer()
        if let preview = layer as? AVCaptureVideoPreviewLayer {
            preview.videoGravity = .resizeAspectFill
        } else if let display = layer as? AVSampleBufferDisplayLayer {
            display.videoGravity = .resizeAspect
        }
        view.hostedLayer = layer
        return view
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {}
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
