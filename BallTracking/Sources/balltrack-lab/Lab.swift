import Foundation

@main
struct Lab {
    static let usage = """
    balltrack-lab — run the HighlightBot ball tracker against a movie file.

    Commands:
      run     --input clip.mp4 --out DIR [--detector vision|luma|motion|default] [--no-annotate] [--debug]
              [--trajectory-length N] [--min-luma N] [--min-motion N] [--max-area N]
              [--threshold N] [--max-candidates N] [--inlier-radius PX] [--min-inliers N] [--window N]
              Writes DIR/track.json, DIR/summary.json, DIR/annotated.mp4 and prints a summary.
              --debug also writes DIR/debug.mp4, a 2x2 mosaic: source | mask / candidates | track.
      audit   --track DIR/track.json --input clip.mp4 --out DIR [--frames 12]
              Zoom audit: crops 80x45 px around the reported position on evenly spaced
              .tracking frames, 6x nearest-neighbour, tiled 4x3 → DIR/audit.png. Look at it.
      extract --input clip.mp4 --out DIR [--every N] [--start SEC] [--end SEC]
              Writes PNG frames named fNNNNN_tSS.SSS.png for labelling.
      mask    --input clip.mp4 --out DIR [--threshold 60] [--dump-frames 18,200]
              Writes DIR/mask.mp4: the two-frame motion mask (white on black), stored orientation.
              --dump-frames also writes those frames' raw mask planes as lossless PGM.
      sizes   --input clip.mp4 --out DIR [--threshold 60] [--min-area 20] [--max-area 800] [--side-by-side]
              Writes DIR/sizes.mp4: mask components coloured by area — white kept, red too large, blue too small.
      candidates --input clip.mp4 --out DIR [--threshold 60] [--max-area 300] [--max-candidates 40]
              Writes DIR/candidates.mp4 (magenta circle per motion candidate) and DIR/candidates.jsonl
              (frame, t, x, y, radius, area, arrivals, fill, confidence; stored-frame pixels).
      score   --track DIR/track.json --truth truth.json [--tolerance 0.02]
              Reports recall, mean error, and false-positive frames against hand labels.
    """

    static func main() async {
        // Line-buffer stdout so progress lines interleave correctly with stderr
        // when the output is piped or captured to a log.
        setvbuf(stdout, nil, _IOLBF, 0)
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            print(usage)
            exit(2)
        }
        args.removeFirst()
        let options = Options(args)
        do {
            switch command {
            case "run": try await RunCommand(options: options).run()
            case "extract": try await ExtractCommand(options: options).run()
            case "mask": try await MaskCommand(options: options).run()
            case "candidates": try await CandidatesCommand(options: options).run()
            case "sizes": try await SizesCommand(options: options).run()
            case "audit": try await AuditCommand(options: options).run()
            case "score": try ScoreCommand(options: options).run()
            case "help", "--help", "-h": print(usage)
            default:
                print(usage)
                throw LabError.usage("unknown command \(command)")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}
