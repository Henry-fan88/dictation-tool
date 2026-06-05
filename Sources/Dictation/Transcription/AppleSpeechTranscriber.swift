import Foundation
import Speech

/// On-device / Apple-hosted transcription via SFSpeechRecognizer. A class so we
/// can retain the recognition task for the duration of the request (the task is
/// cancelled if its reference is dropped).
final class AppleSpeechTranscriber: Transcriber {
    private let localeIdentifier: String
    private let onDevice: Bool
    private var task: SFSpeechRecognitionTask?

    init(localeIdentifier: String, onDevice: Bool) {
        self.localeIdentifier = localeIdentifier
        self.onDevice = onDevice
    }

    func transcribe(audioURL: URL) async throws -> String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            throw DictationError.message("Speech Recognition permission pending — grant it and try again")
        default:
            throw DictationError.message("Speech Recognition permission denied (System Settings ▸ Privacy ▸ Speech Recognition)")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            throw DictationError.message("No speech recognizer for locale \(localeIdentifier)")
        }
        guard recognizer.isAvailable else {
            throw DictationError.message("Speech recognizer is not available right now")
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        if onDevice, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if !finished { finished = true; continuation.resume(throwing: error) }
                    return
                }
                if let result, result.isFinal {
                    if !finished {
                        finished = true
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    }
                }
            }
        }
    }
}
