import CoreMedia
import CoreVideo
import Foundation

public enum SampleBufferError: Error, Equatable {
    case formatDescription(OSStatus)
    case sampleBuffer(OSStatus)
}

/// Wraps a pixel buffer and presentation time into a `CMSampleBuffer`, which is
/// what Vision's stateful requests need to reason about time.
public enum SampleBufferFactory {
    public static func make(pixelBuffer: CVPixelBuffer, time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
        var formatDescription: CMVideoFormatDescription?
        var status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else { throw SampleBufferError.formatDescription(status) }

        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw SampleBufferError.sampleBuffer(status) }
        return sampleBuffer
    }
}
