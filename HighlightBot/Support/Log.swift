import Foundation
import OSLog

/// Unified-logging handles for the app, one per pipeline stage.
///
/// Subsystem is `com.highlightbot.app`. Filter in Console.app / `log stream` with
/// `subsystem == "com.highlightbot.app"` and the category of interest.
enum Log {
    static let subsystem = "com.highlightbot.app"

    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let recorder = Logger(subsystem: subsystem, category: "recorder")
    static let ring = Logger(subsystem: subsystem, category: "ring")
    static let export = Logger(subsystem: subsystem, category: "export")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let voice = Logger(subsystem: subsystem, category: "voice")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}

/// Signposters for Instruments. `capture` brackets every video data callback
/// (interval name `videoCallback`) so the <1 ms budget from the plan can be
/// checked with the os_signpost instrument.
enum Signposts {
    static let capture = OSSignposter(subsystem: Log.subsystem, category: "capture")
}
