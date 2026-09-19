import SwiftUI
import UIKit

/// Loads a JPEG thumbnail from disk off the main actor and shows a placeholder
/// until it arrives (or if the file is missing).
struct ThumbnailImage: View {
    let url: URL?

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .clipped()
        .task(id: url) {
            image = await Self.load(url)
        }
    }

    // VERIFY: UIImage is annotated Sendable in the iOS 17 SDK; if the compiler
    // disagrees, load synchronously on the main actor instead.
    nonisolated private static func load(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
