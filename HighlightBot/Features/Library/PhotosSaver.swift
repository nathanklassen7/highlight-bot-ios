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
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }
            Log.ui.info("Saved \(fileURL.lastPathComponent) to Photos")
        } catch {
            Log.ui.error("Save to Photos failed: \(String(describing: error))")
            throw PhotosSaveError.underlying(error.localizedDescription)
        }
    }
}
