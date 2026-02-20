import AVFoundation
import ApplicationServices
import AppKit

@MainActor
final class PermissionManager {
    static let shared = PermissionManager()

    private init() {}

    // MARK: - Microphone

    var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicrophoneAccess() async -> Bool {
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Accessibility

    var accessibilityAuthorized: Bool {
        AXIsProcessTrusted()
    }

    /// Opens System Settings → Privacy → Accessibility so the user can grant access.
    func requestAccessibilityAccess() {
        // The prompt-based API doesn't always open Settings on macOS 13+.
        // Open directly instead.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Check all required

    func checkAndRequestAll() async {
        if !microphoneAuthorized {
            _ = await requestMicrophoneAccess()
        }
        if !accessibilityAuthorized {
            requestAccessibilityAccess()
        }
    }
}
