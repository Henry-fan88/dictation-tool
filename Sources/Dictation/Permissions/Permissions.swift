import AppKit
import AVFoundation
import Speech
import ApplicationServices

/// Thin wrappers around the three TCC permissions this app needs:
/// Accessibility (event tap + synthetic paste), Microphone, and — when the
/// Apple backend is used — Speech Recognition.
enum Permissions {

    // MARK: Accessibility

    static func accessibilityEnabled() -> Bool {
        AXIsProcessTrusted()
    }

    /// Show the system prompt that deep-links to Privacy & Security ▸ Accessibility.
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Microphone

    static func micStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Ensure mic access, prompting if undetermined. Completion runs on main.
    static func ensureMic(_ completion: @escaping (Bool) -> Void) {
        switch micStatus() {
        case .authorized:
            DispatchQueue.main.async { completion(true) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            DispatchQueue.main.async { completion(false) }
        }
    }

    // MARK: Speech recognition (Apple backend only)

    static func requestSpeech(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }
}
