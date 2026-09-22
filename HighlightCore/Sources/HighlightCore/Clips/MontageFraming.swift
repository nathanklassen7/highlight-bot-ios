import Foundation

/// One montage row's orientation and output timing. The rules work on this
/// rather than on `MontageItem` so they can be exercised without building a
/// whole clip.
public struct MontageFramingInput: Sendable, Equatable {
    public var orientation: ClipOrientation
    public var outputSeconds: Double
    public var width: Int
    public var height: Int

    public init(orientation: ClipOrientation, outputSeconds: Double, width: Int, height: Int) {
        self.orientation = orientation
        self.outputSeconds = outputSeconds
        self.width = width
        self.height = height
    }
}

/// Pure rules for the mixed-orientation montage prompt and render size.
public enum MontageFraming: Sendable {
    /// Distinct effective orientations among the items (`.unknown` → landscape).
    public static func orientations(of items: [MontageFramingInput]) -> Set<ClipOrientation> {
        Set(items.map { $0.orientation.effective })
    }

    /// True when the user must pick which orientation to letterbox against.
    public static func needsChoice(_ items: [MontageFramingInput]) -> Bool {
        orientations(of: items).count > 1
    }

    /// The orientation whose clips contribute the most output seconds. Ties
    /// break landscape, then portrait, then square so the prompt order is stable.
    public static func suggestedOrientation(for items: [MontageFramingInput]) -> ClipOrientation {
        var totals: [ClipOrientation: Double] = [:]
        for item in items {
            let key = item.orientation.effective
            totals[key, default: 0] += max(item.outputSeconds, 0)
        }
        guard let peak = totals.values.max(), peak > 0 else {
            return .landscape
        }
        let tied = totals.filter { $0.value == peak }.map(\.key)
        for candidate in Self.orientationPriority {
            if tied.contains(candidate) { return candidate }
        }
        return .landscape
    }

    /// Largest oriented frame among items matching `orientation`; standard HD
    /// defaults when nothing matches (including legacy `.unknown` rows).
    public static func renderSize(
        for items: [MontageFramingInput],
        keeping orientation: ClipOrientation
    ) -> (width: Int, height: Int) {
        let kept = orientation.effective
        let matching = items.filter { $0.orientation.effective == kept && $0.width > 0 && $0.height > 0 }
        if let best = matching.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            return (best.width, best.height)
        }
        return Self.defaultRenderSize(for: kept)
    }

    /// How many clips will be letterboxed when exporting at `orientation`.
    public static func letterboxedCount(_ items: [MontageFramingInput], keeping orientation: ClipOrientation) -> Int {
        let kept = orientation.effective
        return items.filter { $0.orientation.effective != kept }.count
    }

    // MARK: - Montage items

    public static func orientations(of items: [MontageItem]) -> Set<ClipOrientation> {
        orientations(of: inputs(for: items))
    }

    public static func needsChoice(_ items: [MontageItem]) -> Bool {
        needsChoice(inputs(for: items))
    }

    public static func suggestedOrientation(for items: [MontageItem]) -> ClipOrientation {
        suggestedOrientation(for: inputs(for: items))
    }

    public static func renderSize(
        for items: [MontageItem],
        keeping orientation: ClipOrientation
    ) -> (width: Int, height: Int) {
        renderSize(for: inputs(for: items), keeping: orientation)
    }

    public static func letterboxedCount(_ items: [MontageItem], keeping orientation: ClipOrientation) -> Int {
        letterboxedCount(inputs(for: items), keeping: orientation)
    }

    /// The trim and slow-mo the user chose decide how long a clip runs in the
    /// montage, so the seconds come from `outputDuration`, not the source.
    private static func inputs(for items: [MontageItem]) -> [MontageFramingInput] {
        items.map {
            MontageFramingInput(
                orientation: $0.clip.orientation,
                outputSeconds: $0.outputDuration,
                width: $0.clip.videoWidth,
                height: $0.clip.videoHeight
            )
        }
    }

    private static let orientationPriority: [ClipOrientation] = [.landscape, .portrait, .square]

    private static func defaultRenderSize(for orientation: ClipOrientation) -> (width: Int, height: Int) {
        switch orientation.effective {
        case .landscape: (1920, 1080)
        case .portrait: (1080, 1920)
        case .square: (1080, 1080)
        case .unknown: (1920, 1080)
        }
    }
}
