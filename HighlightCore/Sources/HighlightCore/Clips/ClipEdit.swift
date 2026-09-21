import Foundation

/// The trim and slow-mo settings for one clip, in source seconds. The editor
/// produces one of these; `ClipTrimmer` renders one for a single clip and the
/// montage exporter renders a sequence of them.
public struct ClipEdit: Equatable, Sendable, Codable {
    public var start: Double
    public var end: Double
    public var slowMotion: SlowMotionSegment?
    /// With a segment: play the trim at 1×, then replay the segment slow.
    /// Meaningless (and treated as false) without a segment.
    public var isSlowMotionReplay: Bool

    public init(start: Double, end: Double, slowMotion: SlowMotionSegment? = nil, isSlowMotionReplay: Bool = false) {
        self.start = start
        self.end = end
        self.slowMotion = slowMotion
        self.isSlowMotionReplay = isSlowMotionReplay
    }

    /// The whole clip, untouched.
    public static func full(duration: Double) -> ClipEdit {
        ClipEdit(start: 0, end: max(duration, 0))
    }

    /// A handle within this many seconds of the clip edge counts as untouched.
    /// Matches the editor's snapping.
    public static let edgeTolerance: Double = 0.01

    public var selectedDuration: Double { max(end - start, 0) }

    /// Seconds the rendered clip will run: the selection plus whatever the
    /// slow-mo stretch (or appended replay) adds.
    public var outputDuration: Double {
        guard let slowMotion else { return selectedDuration }
        return selectedDuration + slowMotion.addedDuration(replay: isSlowMotionReplay)
    }

    public func isTrimmed(clipDuration: Double) -> Bool {
        start > Self.edgeTolerance || end < clipDuration - Self.edgeTolerance
    }

    /// True once a handle has moved or slow-mo has been added.
    public func hasChanges(clipDuration: Double) -> Bool {
        isTrimmed(clipDuration: clipDuration) || slowMotion != nil
    }

    /// Fits the edit into `0...duration`, keeping at least `minimumDuration`
    /// selected when the clip allows it. For edits made against a record whose
    /// `duration` disagrees with the file, or a clip that has since been
    /// trimmed.
    public func clamped(toClipDuration duration: Double, minimumDuration: Double) -> ClipEdit {
        var result = self
        result.end = min(max(end, 0), duration)
        let latestStart = max(result.end - minimumDuration, 0)
        result.start = min(max(start, 0), latestStart)
        result.slowMotion = slowMotion?.clamped(to: result.start, result.end)
        if result.slowMotion == nil {
            result.isSlowMotionReplay = false
        }
        return result
    }
}
