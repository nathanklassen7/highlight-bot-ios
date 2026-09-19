import HighlightCore
import SwiftUI

/// Monospaced dump of `PipelineMetrics`, shown on the Record screen when
/// `RecordingConfig.debugOverlayEnabled` is on.
struct DebugOverlay: View {
    let metrics: PipelineMetrics

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(.green)
            .multilineTextAlignment(.leading)
            .padding(8)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .allowsHitTesting(false)
            .accessibilityLabel("Debug metrics")
    }

    private var text: String {
        let freeMB = Double(metrics.freeBytes) / 1_048_576
        let session = metrics.sessionID.map { String($0.rawValue.uuidString.prefix(8)) } ?? "—"
        return """
        captured   \(metrics.capturedFrames)
        dropped    \(metrics.droppedFrames)
        analyzerDr \(metrics.analyzerDroppedFrames)
        buffered   \(format(metrics.bufferedSeconds, 1)) s
        seg write  \(format(metrics.lastSegmentWriteMillis, 1)) ms
        export     \(format(metrics.lastExportSeconds, 2)) s
        callback   \(format(metrics.lastCallbackMicros, 0)) µs
        thermal    \(thermalName(metrics.thermalState))
        free       \(format(freeMB, 0)) MB
        fps        \(metrics.currentFrameRate)
        session    \(session)
        """
    }

    private func format(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    private func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
