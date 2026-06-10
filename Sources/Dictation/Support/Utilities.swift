import Foundation

/// User-facing error with a plain message.
enum DictationError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

/// The lifecycle the app moves through for a single dictation.
enum AppState: Equatable {
    case idle
    case settingUp(String) // one-time local-Whisper provisioning, with progress text
    case recording
    case transcribing
    case organizing
    case inserting
    case error(String)
}

extension String {
    /// Drop a single trailing slash so we can join URL paths predictably.
    var trimmingTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}

extension Data {
    /// Append UTF-8 bytes of a string (used when building multipart bodies).
    mutating func appendString(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}

enum HTTP {
    /// Throw a descriptive error for any non-2xx response.
    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DictationError.message("HTTP \(http.statusCode): \(body.prefix(400))")
        }
    }
}
