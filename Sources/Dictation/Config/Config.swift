import Foundation
import AppKit

// MARK: - Config model

enum TranscriptionBackend: String, Codable {
    case cloud   // hosted Whisper-style STT API
    case apple   // on-device SFSpeechRecognizer
}

enum LLMProviderKind: String, Codable {
    case openaiCompatible // openai, gemini, deepseek, kimi, glm, openrouter, local...
    case anthropic        // claude native /v1/messages
}

enum InsertionMethod: String, Codable {
    case paste // clipboard + ⌘V (reliable, fast for long text)
    case type  // synthesize unicode keystrokes
}

/// A secret is read from `key` if non-empty, otherwise from the env var named
/// in `keyEnv`. Lets users keep keys out of the plaintext config if they wish.
struct Secret: Codable {
    var key: String = ""
    var keyEnv: String = ""

    var resolved: String? {
        if !key.isEmpty { return key }
        if !keyEnv.isEmpty, let v = ProcessInfo.processInfo.environment[keyEnv], !v.isEmpty {
            return v
        }
        return nil
    }
}

struct CloudSTTConfig: Codable {
    var baseURL: String = "https://api.openai.com/v1"
    var model: String = "whisper-1"
    var apiKey: String = ""
    var apiKeyEnv: String = "OPENAI_API_KEY"
    var language: String? = nil   // ISO-639-1, e.g. "en"; nil = auto-detect

    var secret: Secret { Secret(key: apiKey, keyEnv: apiKeyEnv) }
}

struct AppleSTTConfig: Codable {
    var locale: String = "en-US"
    var onDevice: Bool = false    // true = never leaves the machine (lower accuracy)
}

struct TranscriptionConfig: Codable {
    // Default to on-device Apple speech so a fresh install works with no API key.
    var backend: TranscriptionBackend = .apple
    var cloud: CloudSTTConfig = .init()
    var apple: AppleSTTConfig = .init()
}

struct LLMConfig: Codable {
    // Off by default so first run works with no key; turn on once a key is set.
    var enabled: Bool = false
    var provider: LLMProviderKind = .openaiCompatible
    var baseURL: String = "https://api.openai.com/v1"
    var model: String = "gpt-4o-mini"
    var apiKey: String = ""
    var apiKeyEnv: String = "OPENAI_API_KEY"
    var systemPrompt: String = AppConfig.defaultSystemPrompt
    var temperature: Double = 0.3
    var maxTokens: Int = 1024

    var secret: Secret { Secret(key: apiKey, keyEnv: apiKeyEnv) }
}

struct HotkeyConfig: Codable {
    /// Swallow the bare fn (globe) key so it doesn't also trigger the system
    /// emoji picker / dictation. Set "Press globe key to: Do Nothing" for best
    /// results, or leave this true to suppress it for us.
    var suppressFnDefault: Bool = true
}

struct InsertionConfig: Codable {
    var method: InsertionMethod = .paste
    var restoreClipboard: Bool = true
}

struct AppConfig: Codable {
    var transcription: TranscriptionConfig = .init()
    var llm: LLMConfig = .init()
    var hotkey: HotkeyConfig = .init()
    var insertion: InsertionConfig = .init()

    static let defaultSystemPrompt = """
    You are a dictation assistant. The user spoke text that was transcribed by \
    speech-to-text and may contain disfluencies, filler words, run-ons, and \
    transcription errors. Rewrite it into clean, well-punctuated, organized text \
    that preserves the user's meaning and intent. Do not add new information, do \
    not answer questions contained in the text, and do not include any preamble \
    or explanation. Output only the cleaned-up text, ready to paste.
    """

    static let `default` = AppConfig()
}

// MARK: - Config persistence

enum ConfigStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/dictation-tool", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("config.json")
    }

    /// Load the config, creating a default one on first run.
    static func loadOrCreate() -> AppConfig {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            let config = AppConfig.default
            save(config)
            return config
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            NSLog("Dictation: failed to read config (%@); using defaults", "\(error)")
            return AppConfig.default
        }
    }

    static func save(_ config: AppConfig) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(config)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Dictation: failed to write config: %@", "\(error)")
        }
    }

    /// Human-readable report of what the app actually loads. Used by the
    /// `--check-config` CLI flag so config problems are visible, not silent.
    static func diagnose() -> String {
        var lines: [String] = ["Config path: \(fileURL.path)"]
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            lines.append("STATUS: no config file — built-in defaults would be used")
            return lines.joined(separator: "\n")
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let cfg = try JSONDecoder().decode(AppConfig.self, from: data)
            lines.append("Decode: OK")
            lines.append("transcription.backend = \(cfg.transcription.backend.rawValue)")
            lines.append("llm.enabled  = \(cfg.llm.enabled)")
            lines.append("llm.provider = \(cfg.llm.provider.rawValue)")
            lines.append("llm.model    = \(cfg.llm.model)")
            lines.append("llm.baseURL  = \(cfg.llm.baseURL)")
            lines.append("llm key resolves: \(cfg.llm.secret.resolved != nil)")
        } catch {
            lines.append("Decode: FAILED -> \(error)")
            lines.append("STATUS: app FALLS BACK to defaults (backend=apple, llm.enabled=false) — Gemini silently off!")
        }
        return lines.joined(separator: "\n")
    }

    /// Open the config file in the user's default editor.
    static func openInEditor() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            save(AppConfig.default)
        }
        NSWorkspace.shared.open(fileURL)
    }
}
