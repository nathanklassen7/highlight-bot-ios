import Foundation

/// Pure segment-selection math. No I/O.
public enum ClipAssembler {
    /// Selects the segments for a clip covering at least `lastSeconds`.
    ///
    /// Filters `segments` to `sessionID`, requires an initialization segment,
    /// sorts media by `seq`, then walks backwards from the newest media
    /// segment while the accumulated duration is below `lastSeconds`. The walk
    /// stops at the first gap in `seq`, so the result is always contiguous.
    /// Whole segments only: when enough footage exists the plan's duration is
    /// at least `lastSeconds`; when it does not, everything contiguous with
    /// the newest segment is returned. The newest segment is always included.
    ///
    /// Returns nil if there is no initialization segment or no media.
    public static func plan(
        segments: [Segment],
        sessionID: SessionID,
        lastSeconds: TimeInterval
    ) -> ClipPlan? {
        let session = segments.filter { $0.sessionID == sessionID }
        guard let initialization = session
            .filter({ $0.kind == .initialization })
            .min(by: { $0.seq < $1.seq })
        else { return nil }

        let media = session.filter { $0.kind == .media }.sorted { $0.seq < $1.seq }
        guard !media.isEmpty else { return nil }

        // Walk newest → oldest, collecting into `reversed` (newest first).
        var reversed: [Segment] = []
        var accumulated: TimeInterval = 0
        var cursor = media.count - 1
        while cursor >= 0, reversed.isEmpty || accumulated < lastSeconds {
            let candidate = media[cursor]
            if let oldestChosen = reversed.last, oldestChosen.seq != candidate.seq + 1 {
                break
            }
            reversed.append(candidate)
            accumulated += candidate.duration
            cursor -= 1
        }

        return ClipPlan(
            sessionID: sessionID,
            initializationSegment: initialization,
            mediaSegments: reversed.reversed()
        )
    }
}
