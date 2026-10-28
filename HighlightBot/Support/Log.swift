import Foundation
import OSLog

/// Unified-logging handles for the app, one per pipeline stage.
///
/// Only failures are logged (`error` and `fault`), so a tester's sysdiagnose
/// explains why something broke without any per-frame or per-segment noise.
/// Subsystem is `com.nathanklassen.highlightbot`. Filter in Console.app / `log stream` with
/// `subsystem == "com.nathanklassen.highlightbot"` and the category of interest.
enum Log {
    static let subsystem = "com.nathanklassen.highlightbot"

    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let recorder = Logger(subsystem: subsystem, category: "recorder")
    static let ring = Logger(subsystem: subsystem, category: "ring")
    static let export = Logger(subsystem: subsystem, category: "export")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let voice = Logger(subsystem: subsystem, category: "voice")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let store = Logger(subsystem: subsystem, category: "store")
}
