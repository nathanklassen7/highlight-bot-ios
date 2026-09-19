import BallTracking
import CoreGraphics
import Foundation

/// Hand labels. `points` are ball centres (normalised, top-left origin) at given
/// times; `absent` are time ranges where no ball is in play.
struct GroundTruth: Codable {
    struct Point: Codable { var time: Double; var x: Double; var y: Double }
    struct Range: Codable { var start: Double; var end: Double }
    var points: [Point]
    var absent: [Range]
}

struct ScoreCommand {
    let options: Options

    func run() throws {
        let trackURL = expandPath(try options.required("track"))
        let truthURL = expandPath(try options.required("truth"))
        let tolerance = options.double("tolerance", default: 0.02)

        let track = try JSONDecoder().decode(BallTrack.self, from: Data(contentsOf: trackURL))
        let truth = try JSONDecoder().decode(GroundTruth.self, from: Data(contentsOf: truthURL))

        var hits = 0
        var errors: [Double] = []
        for point in truth.points {
            guard let frame = track.frame(at: point.time), frame.isVisible, let position = frame.position else { continue }
            let error = hypot(position.x - point.x, position.y - point.y)
            if error <= tolerance {
                hits += 1
                errors.append(error)
            }
        }

        var absentFrames = 0
        var falsePositives = 0
        for frame in track.frames where truth.absent.contains(where: { frame.time >= $0.start && frame.time <= $0.end }) {
            absentFrames += 1
            if frame.isVisible { falsePositives += 1 }
        }

        let recall = truth.points.isEmpty ? 0 : Double(hits) / Double(truth.points.count)
        let meanError = errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count)
        let fpRate = absentFrames == 0 ? 0 : Double(falsePositives) / Double(absentFrames)
        print(String(format: "labelled points   %d", truth.points.count))
        print(String(format: "recall            %.1f%% (%d within %.3f)", recall * 100, hits, tolerance))
        print(String(format: "mean error        %.4f (fraction of frame)", meanError))
        print(String(format: "absent frames     %d, visible in %d (%.1f%% false-positive rate)", absentFrames, falsePositives, fpRate * 100))
    }
}
