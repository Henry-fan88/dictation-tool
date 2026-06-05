import AppKit

/// Orchestrates the full flow: record → transcribe → organize → insert, and
/// publishes state changes so the menu bar can reflect progress. Backends are
/// rebuilt from config on every run so "Reload Config" takes effect immediately.
final class DictationController {

    /// Notified on the main queue whenever `state` changes.
    var onStateChange: ((AppState) -> Void)?

    private(set) var state: AppState = .idle {
        didSet { publish(state) }
    }

    private var config: AppConfig
    private let recorder = AudioRecorder()
    private let inserter = TextInserter()

    init(config: AppConfig) {
        self.config = config
    }

    func updateConfig(_ config: AppConfig) {
        self.config = config
    }

    /// fn-key entry point. Starts when idle, finishes when recording, ignores
    /// presses while busy transcribing/organizing.
    func toggle() {
        switch state {
        case .idle, .error:
            startRecording()
        case .recording:
            stopAndProcess()
        case .transcribing, .organizing, .inserting:
            break // busy — ignore
        }
    }

    // MARK: Recording

    private func startRecording() {
        guard Permissions.accessibilityEnabled() else {
            state = .error("Grant Accessibility permission, then try again")
            Permissions.promptAccessibility()
            return
        }
        Permissions.ensureMic { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.state = .error("Microphone access denied")
                return
            }
            do {
                try self.recorder.start()
                self.state = .recording
            } catch {
                self.state = .error(self.describe(error))
            }
        }
    }

    // MARK: Processing pipeline

    private func stopAndProcess() {
        guard let audioURL = recorder.stop() else {
            state = .idle
            return
        }
        state = .transcribing
        let config = self.config
        Log.write("stop: backend=\(config.transcription.backend.rawValue) llm.enabled=\(config.llm.enabled) provider=\(config.llm.provider.rawValue) model=\(config.llm.model)")

        Task { [weak self] in
            guard let self else { return }
            do {
                let transcriber = try self.makeTranscriber(config)
                var text = try await transcriber.transcribe(audioURL: audioURL)
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                Log.write("transcript (\(text.count) chars): \(text.prefix(160))")

                if config.llm.enabled, !text.isEmpty {
                    let provider = try self.makeProvider(config)
                    await self.setState(.organizing)
                    Log.write("organizing via \(config.llm.provider.rawValue)/\(config.llm.model)…")
                    text = try await provider.organize(
                        transcript: text,
                        systemPrompt: config.llm.systemPrompt
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    Log.write("organized (\(text.count) chars): \(text.prefix(160))")
                } else {
                    Log.write("LLM step skipped (enabled=\(config.llm.enabled), empty=\(text.isEmpty)) — inserting raw")
                }

                try? FileManager.default.removeItem(at: audioURL)

                guard !text.isEmpty else {
                    await self.setState(.idle)
                    return
                }

                let finalText = text
                Log.write("inserting \(finalText.count) chars")
                await MainActor.run {
                    self.state = .inserting
                    self.inserter.insert(
                        finalText,
                        method: config.insertion.method,
                        restoreClipboard: config.insertion.restoreClipboard
                    )
                    self.state = .idle
                }
            } catch {
                try? FileManager.default.removeItem(at: audioURL)
                Log.write("ERROR: \(self.describe(error))")
                await self.setState(.error(self.describe(error)))
            }
        }
    }

    // MARK: Backend factories

    private func makeTranscriber(_ config: AppConfig) throws -> Transcriber {
        switch config.transcription.backend {
        case .apple:
            return AppleSpeechTranscriber(
                localeIdentifier: config.transcription.apple.locale,
                onDevice: config.transcription.apple.onDevice
            )
        case .cloud:
            guard let key = config.transcription.cloud.secret.resolved else {
                throw DictationError.message("No transcription API key set in config")
            }
            return WhisperCloudTranscriber(
                baseURL: config.transcription.cloud.baseURL,
                model: config.transcription.cloud.model,
                apiKey: key,
                language: config.transcription.cloud.language
            )
        }
    }

    private func makeProvider(_ config: AppConfig) throws -> LLMProvider {
        guard let key = config.llm.secret.resolved else {
            throw DictationError.message("No LLM API key set in config")
        }
        switch config.llm.provider {
        case .openaiCompatible:
            return OpenAICompatibleProvider(
                baseURL: config.llm.baseURL,
                model: config.llm.model,
                apiKey: key,
                temperature: config.llm.temperature,
                maxTokens: config.llm.maxTokens
            )
        case .anthropic:
            return AnthropicProvider(
                baseURL: config.llm.baseURL,
                model: config.llm.model,
                apiKey: key,
                temperature: config.llm.temperature,
                maxTokens: config.llm.maxTokens
            )
        }
    }

    // MARK: Helpers

    @MainActor
    private func setState(_ newState: AppState) {
        state = newState
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? DictationError, let m = e.errorDescription { return m }
        return error.localizedDescription
    }

    private func publish(_ state: AppState) {
        if Thread.isMainThread {
            onStateChange?(state)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
        }
    }
}
