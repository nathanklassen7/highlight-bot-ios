import Foundation

/// Where the recording session is. Saving is a task, not a state; the number
/// of in-flight saves rides along on `.recording`.
public enum SessionState: Sendable, Equatable, Hashable {
    case idle
    /// `backend.startRecording()` is in progress.
    case starting
    case recording(pendingSaves: Int)
    /// Capture interrupted (phone call, background); will resume.
    case interrupted
    /// `backend.stopRecording()` is in progress.
    case stopping

    /// True for `.recording` and `.interrupted`.
    public var isRecording: Bool {
        switch self {
        case .recording, .interrupted: true
        case .idle, .starting, .stopping: false
        }
    }
}

/// Something the UI wants to know about.
public enum SessionEvent: Sendable, Equatable {
    case stateChanged(SessionState)
    case clipSaved(ClipRecord)
    case saveFailed(reason: String)
    case startFailed(reason: String)
    case inactivityTimeoutFired
    /// Fired once, `secondsRemaining` before the inactivity timeout.
    case inactivityWarning(secondsRemaining: TimeInterval)
}
