import Foundation
import Observation
import AVFoundation
import Photos

/// App-level view of a system permission.
enum PermissionStatus: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
    case restricted
}

/// Camera, microphone, and add-only Photos permissions, observable by SwiftUI.
/// `refresh()` re-reads the system state; the `request*` methods prompt only
/// when the status is `.notDetermined` and then refresh.
@MainActor
@Observable
final class PermissionsManager {
    var camera: PermissionStatus = .notDetermined
    var microphone: PermissionStatus = .notDetermined
    var photosAddOnly: PermissionStatus = .notDetermined

    init() {
        refresh()
    }

    func refresh() {
        camera = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        microphone = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        photosAddOnly = Self.map(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    func requestCamera() async -> PermissionStatus {
        if camera == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        refresh()
        return camera
    }

    func requestMicrophone() async -> PermissionStatus {
        if microphone == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        refresh()
        return microphone
    }

    func requestPhotosAddOnly() async -> PermissionStatus {
        if photosAddOnly == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        refresh()
        return photosAddOnly
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    private static func map(_ status: PHAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized, .limited: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}
