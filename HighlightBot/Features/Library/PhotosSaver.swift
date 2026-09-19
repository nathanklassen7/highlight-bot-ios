import Foundation
import Photos
import os

/// Why a Save to Photos attempt failed.
enum PhotosSaveError: Error, LocalizedError {
    case permissionDenied
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Photos access was not granted."
        case .underlying(let message): message
        }
    }
}

/// Copies a clip into the user's Photos library using add-only access.
@MainActor
enum PhotosSaver {
    /// Requests add-only permission if needed, then creates a video asset from `fileURL`.
    static func save(_ fileURL: URL, permissions: PermissionsManager) async throws {
        let status = await permissions.requestPhotosAddOnly()
        guard status == .granted else { throw PhotosSaveError.permissionDenied }

        do {
            try await Self.addVideo(at: fileURL)
            Log.ui.info("Saved \(fileURL.lastPathComponent) to Photos")
        } catch {
            Log.ui.error("Save to Photos failed: \(String(describing: error))")
            throw PhotosSaveError.underlying(error.localizedDescription)
        }
    }

    /// Photos runs the change block on its own queue and the block is not
    /// `NS_SWIFT_SENDABLE` in the header. A plain closure formed in this
    /// `@MainActor` type inherits main-actor isolation and the Swift 6
    /// runtime traps when Photos invokes it off-main. Hence `nonisolated`
    /// plus an explicit `@Sendable` block.
    private nonisolated static func addVideo(at fileURL: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        }
    }
}
