import Foundation

@main
struct Lab {
    static let usage = """
    balltrack-lab — run the HighlightBot ball tracker against a movie file.

    Commands:
      run     --input clip.mp4 --out DIR [--detector vision|luma|default] [--no-annotate]
              [--trajectory-length N] [--min-luma N] [--min-motion N] [--max-area N]
              Writes DIR/track.json, DIR/summary.json, DIR/annotated.mp4 and prints a summary.
      extract --input clip.mp4 --out DIR [--every N] [--start SEC] [--end SEC]
              Writes PNG frames named fNNNNN_tSS.SSS.png for labelling.
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
