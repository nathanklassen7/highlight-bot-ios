import AVFoundation
import CoreGraphics
import Foundation
import HighlightCore

/// Builds the composition a montage export renders.
///
/// Video gets one composition track; items are appended in order at a
/// running cursor. Slow-mo is applied with `scaleTimeRange` immediately after
/// each item is inserted, before the cursor moves on, so a later item is
/// never shifted under an earlier scale. The cursor is read back from the
/// composition after every item rather than predicted, so the instruction
/// ranges tile exactly what was built. This is
/// `ClipTrimmer.composition(of:range:slowMotion:replay:)` generalised to N
/// items.
///
/// Edits are intersected with what the source file actually contains, since
/// `ClipRecord.duration` can overstate it.
///
/// Audio is only added when at least one source has it; silent sources leave
/// a gap that is padded so later audio stays aligned with the video.
///
/// A video composition carries each item's orientation: one instruction per
/// item whose layer transform applies the source's `preferredTransform` and
/// letterboxes it into the first item's oriented frame. A single
/// `preferredTransform` on the track would render mixed portrait/landscape
/// sources wrong.
enum MontageComposition {
    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        /// One per item, in order; prices the encode for the time estimate.
        let workloads: [ExportWorkload]
    }

    static let timescale: CMTimeScale = 600

    static func build(_ items: [MontageItem]) async throws -> Built {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.exportFailed("Could not add a video track to the composition.")
        }
        var audio: AVMutableCompositionTrack?

        var cursor = CMTime.zero
        var renderSize: CGSize?
        var frameDuration = CMTime(value: 1, timescale: 30)
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var workloads: [ExportWorkload] = []

        for (index, item) in items.enumerated() {
            let asset = AVURLAsset(url: item.clip.fileURL)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw TrimError.noVideoTrack
            }
            let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
            let (naturalSize, transform, frameRate, sourceTimeRange) = try await sourceVideo.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .timeRange
            )

            // The first item decides the output frame and frame rate.
            let frame: CGSize
            if let existing = renderSize {
                frame = existing
            } else {
                let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform)
                frame = CGSize(width: abs(oriented.width), height: abs(oriented.height))
                renderSize = frame
                if frameRate > 0 {
                    frameDuration = CMTime(value: 1, timescale: max(1, CMTimeScale(frameRate.rounded())))
                }
            }

            let edit = item.edit
            let requested = CMTimeRange(start: time(edit.start), end: time(edit.end))
            let range = requested.intersection(sourceTimeRange)
            guard range.duration.seconds > 0 else {
                throw MontageError.clip(index: index, underlying: TrimError.rangeOutOfBounds)
            }
            let itemStart = cursor
            try video.insertTimeRange(range, of: sourceVideo, at: cursor)
            if let sourceAudio {
                if audio == nil {
                    audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                if let audio {
                    try await padAudio(audio, to: cursor)
                    try audio.insertTimeRange(range, of: sourceAudio, at: cursor)
                }
            }
            // Only feeds the time estimate; the timeline below is read from
            // the composition, not from this.
            var predictedDuration = range.duration
            var retimedSeconds: Double = 0

            // A segment the source clamp swallowed entirely has nothing to slow.
            if let clamped = edit.slowMotion?.clamped(to: range.start.seconds, range.end.seconds, minimumDuration: 0),
               clamped.duration > 0 {
                let segment = CMTimeRange(start: time(clamped.start), duration: time(clamped.duration))
                let scaled = time(clamped.scaledDuration)
                if edit.isSlowMotionReplay {
                    // 1× pass, then the segment again, slowed.
                    let replayAt = try await composition.load(.duration)
                    try video.insertTimeRange(segment, of: sourceVideo, at: replayAt)
                    if let sourceAudio, let audio {
                        try await padAudio(audio, to: replayAt)
                        try audio.insertTimeRange(segment, of: sourceAudio, at: replayAt)
                    }
                    composition.scaleTimeRange(CMTimeRange(start: replayAt, duration: segment.duration), toDuration: scaled)
                    retimedSeconds = scaled.seconds
                    predictedDuration = range.duration + scaled
                } else {
                    // Composition time for this item starts at `cursor` where the
                    // source starts at `range.start`.
                    let slowAt = cursor + (segment.start - range.start)
                    composition.scaleTimeRange(CMTimeRange(start: slowAt, duration: segment.duration), toDuration: scaled)
                    retimedSeconds = scaled.seconds
                    predictedDuration = range.duration - segment.duration + scaled
                }
            }

            // Instructions must tile the composition exactly, or the export
            // fails with `AVError.invalidVideoComposition`; read the end of
            // this item from the composition rather than predicting it.
            cursor = try await composition.load(.duration)

            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
            layer.setTransform(fitTransform(naturalSize: naturalSize, preferredTransform: transform, into: frame), at: itemStart)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: itemStart, end: cursor)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            // Every item is re-encoded at the first item's frame, so the
            // render size prices the encode, not the source's natural size.
            workloads.append(ExportWorkload(
                outputSeconds: predictedDuration.seconds,
                frameRate: Double(frameRate),
                pixelCount: Double(frame.width * frame.height),
                retimedSeconds: retimedSeconds
            ))
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize ?? CGSize(width: 1920, height: 1080)
        videoComposition.frameDuration = frameDuration
        videoComposition.instructions = instructions
        return Built(composition: composition, videoComposition: videoComposition, workloads: workloads)
    }

    /// Orients `naturalSize` with `preferredTransform`, then scales it to fit
    /// inside `renderSize` and centres it. Sources that already match the
    /// render size get exactly `preferredTransform` moved to the origin.
    static func fitTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform, into renderSize: CGSize) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        guard oriented.width > 0, oriented.height > 0 else { return preferredTransform }
        let scale = min(renderSize.width / oriented.width, renderSize.height / oriented.height)
        let dx = (renderSize.width - oriented.width * scale) / 2
        let dy = (renderSize.height - oriented.height * scale) / 2
        // Apply the source transform, drag the rotated frame's origin to zero,
        // scale, then centre. `concatenating` applies left to right.
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: dx, y: dy))
    }

    /// Fills the audio track with silence up to `insertAt` when it ends
    /// earlier, so audio inserted there lines up with the video that was
    /// already placed. Needed after an item without audio.
    private static func padAudio(_ audio: AVMutableCompositionTrack, to insertAt: CMTime) async throws {
        let timeRange = try await audio.load(.timeRange)
        // An empty track has no meaningful range yet; treat it as ending at 0.
        let end = timeRange.isValid ? timeRange.end : .zero
        if end < insertAt {
            audio.insertEmptyTimeRange(CMTimeRange(start: end, end: insertAt))
        }
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }
}
