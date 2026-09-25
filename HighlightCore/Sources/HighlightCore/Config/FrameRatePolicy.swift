import Foundation

/// Decides what frame rate the camera should run right now. The configured
/// rate is what the user asked to record at; everything here only lowers it.
///
/// Sensor readout and ISP work scale with frame rate, so the camera runs at
/// `idleFrameRate` whenever the viewfinder is live but nothing is being
/// recorded. While recording, thermal pressure and Low Power Mode both pull
/// the rate down to `reducedFrameRate`; heat and battery are the same problem
/// on a phone in the sun for an hour.
public enum FrameRatePolicy {
    /// Rate for a live viewfinder that is not recording.
    public static let idleFrameRate = 30
    /// Rate while recording under thermal pressure or in Low Power Mode.
    public static let reducedFrameRate = 30

    /// The rate to run, never above `configured`.
    public static func target(
        configured: Int,
        isRecording: Bool,
        thermalState: ProcessInfo.ThermalState,
        lowPowerMode: Bool
    ) -> Int {
        guard isRecording else { return min(idleFrameRate, configured) }
        if lowPowerMode { return min(reducedFrameRate, configured) }
        switch thermalState {
        case .serious, .critical:
            return min(reducedFrameRate, configured)
        case .nominal, .fair:
            return configured
        @unknown default:
            return configured
        }
    }
}
