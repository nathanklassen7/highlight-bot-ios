import HighlightCore
import SwiftUI
import UIKit

/// Resolves and loads a JPEG thumbnail off the main actor and shows a
/// placeholder until it arrives (or if the file is missing). Takes the file
/// name rather than a URL so `body` never touches the file system.
///
/// Decoded images are kept in a small in-memory cache so a thumbnail that has
/// been shown once renders synchronously the next time (the player relies on
/// this when a swiped-to neighbour becomes the current clip's backdrop).
struct ThumbnailImage: View {
    let fileName: String?
    /// `.fill` crops to the frame (grid cells); `.fit` letterboxes like the player.
    var contentMode: ContentMode = .fill

    /// The most recent async load, tagged with the file it belongs to so a
    /// stale image is never shown after `fileName` changes.
    @State private var loaded: (fileName: String?, image: UIImage?) = (nil, nil)

    private static let cache = NSCache<NSString, UIImage>()

    // The image sits in an overlay rather than a ZStack: a `.fill` image
    // reports a size bigger than the space it was offered on one axis, and a
    // ZStack would adopt that size, so the view spilled past whatever frame
    // the caller clipped it to. An overlay cannot change the black backdrop's
    // size, which is the one the caller asked for.
    var body: some View {
        Color.black
            .overlay {
                if let image = displayedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    Image(systemName: "film")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .clipped()
            .task(id: fileName) {
                if let cached = Self.cached(fileName) {
                    loaded = (fileName, cached)
                    return
                }
                let image = await Self.load(fileName)
                if let image, let fileName {
                    Self.cache.setObject(image, forKey: fileName as NSString)
                }
                loaded = (fileName, image)
            }
    }

    /// Cache first so a change of `fileName` can render without a frame of
    /// placeholder; otherwise the async result, only if it is for this file.
    private var displayedImage: UIImage? {
        if let cached = Self.cached(fileName) { return cached }
        return loaded.fileName == fileName ? loaded.image : nil
    }

    private static func cached(_ fileName: String?) -> UIImage? {
        guard let fileName else { return nil }
        return cache.object(forKey: fileName as NSString)
    }

    // VERIFY: UIImage is annotated Sendable in the iOS 17 SDK; if the compiler
    // disagrees, load synchronously on the main actor instead.
    nonisolated private static func load(_ fileName: String?) async -> UIImage? {
        guard let url = ClipRecord.resolveThumbnailURL(fileName: fileName) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
