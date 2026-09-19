import HighlightCore
import SwiftUI
import UIKit

/// Resolves and loads a JPEG thumbnail off the main actor and shows a
/// placeholder until it arrives (or if the file is missing). Takes the file
/// name rather than a URL so `body` never touches the file system.
struct ThumbnailImage: View {
    let fileName: String?

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
        .task(id: fileName) {
            image = await Self.load(fileName)
        }
    }

    // VERIFY: UIImage is annotated Sendable in the iOS 17 SDK; if the compiler
    // disagrees, load synchronously on the main actor instead.
    nonisolated private static func load(_ fileName: String?) async -> UIImage? {
        guard let url = ClipRecord.resolveThumbnailURL(fileName: fileName) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
