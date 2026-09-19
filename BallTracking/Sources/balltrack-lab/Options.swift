import Foundation

/// Minimal `--key value` / `--flag` parser. No positional arguments.
struct Options {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let arg = args[i]
            guard arg.hasPrefix("--") else { i += 1; continue }
            let key = String(arg.dropFirst(2))
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                values[key] = args[i + 1]
                i += 2
            } else {
                flags.insert(key)
                i += 1
            }
        }
    }

    func string(_ key: String) -> String? { values[key] }

    func required(_ key: String) throws -> String {
        guard let value = values[key] else { throw LabError.usage("missing --\(key)") }
        return value
    }

    func int(_ key: String, default fallback: Int) -> Int { values[key].flatMap(Int.init) ?? fallback }
    func double(_ key: String, default fallback: Double) -> Double { values[key].flatMap(Double.init) ?? fallback }
    func flag(_ key: String) -> Bool { flags.contains(key) }
}

enum LabError: Error, CustomStringConvertible {
    case usage(String)
    case failed(String)

    var description: String {
        switch self {
        case .usage(let message): "usage error: \(message)"
        case .failed(let message): message
        }
    }
}

func expandPath(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
}
