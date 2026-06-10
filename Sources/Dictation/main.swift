import AppKit

// Diagnostic: print exactly what config the app would load, then exit. Run with
//   .build/release/Dictation --check-config
if CommandLine.arguments.contains("--check-config") {
    print(ConfigStore.diagnose())
    exit(0)
}

// Diagnostic: run the real LLM organize path against a messy sample, no GUI/mic.
//   .build/release/Dictation --test-llm
if CommandLine.arguments.contains("--test-llm") {
    let cfg = ConfigStore.loadOrCreate()
    let sample = "um so like i wanted to say that the the meeting is uh moved to tuesday at 3 ok thanks"
    guard let key = cfg.llm.secret.resolved else {
        print("No LLM key resolves from config."); exit(1)
    }
    let provider: LLMProvider = cfg.llm.provider == .anthropic
        ? AnthropicProvider(baseURL: cfg.llm.baseURL, model: cfg.llm.model, apiKey: key,
                            temperature: cfg.llm.temperature, maxTokens: cfg.llm.maxTokens)
        : OpenAICompatibleProvider(baseURL: cfg.llm.baseURL, model: cfg.llm.model, apiKey: key,
                                   temperature: cfg.llm.temperature, maxTokens: cfg.llm.maxTokens)
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let out = try await provider.organize(transcript: sample, systemPrompt: cfg.llm.systemPrompt)
            print("INPUT:\n\(sample)\n\nOUTPUT:\n\(out)")
        } catch {
            print("LLM ERROR: \(error)")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// Diagnostic: run the configured transcription backend on a WAV file, no GUI/mic.
//   .build/release/Dictation --transcribe /path/to/audio.wav
if let flagIndex = CommandLine.arguments.firstIndex(of: "--transcribe") {
    guard CommandLine.arguments.count > flagIndex + 1 else {
        print("usage: Dictation --transcribe <audio.wav>"); exit(1)
    }
    let audioURL = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    let cfg = ConfigStore.loadOrCreate()
    print("backend: \(cfg.transcription.backend.rawValue)")
    let transcriber: Transcriber
    switch cfg.transcription.backend {
    case .apple:
        transcriber = AppleSpeechTranscriber(localeIdentifier: cfg.transcription.apple.locale,
                                             onDevice: cfg.transcription.apple.onDevice)
    case .cloud:
        guard let key = cfg.transcription.cloud.secret.resolved else {
            print("No transcription key resolves from config."); exit(1)
        }
        transcriber = WhisperCloudTranscriber(baseURL: cfg.transcription.cloud.baseURL,
                                              model: cfg.transcription.cloud.model,
                                              apiKey: key,
                                              language: cfg.transcription.cloud.language)
    case .local:
        transcriber = WhisperLocalTranscriber(config: cfg.transcription.local)
    }
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let text = try await transcriber.transcribe(audioURL: audioURL)
            print("TRANSCRIPT:\n\(text)")
        } catch {
            print("TRANSCRIBE ERROR: \(error.localizedDescription)")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// Diagnostic: provision the local Whisper backend headlessly (download the
// model + create the managed Python env), no GUI. Useful for testing and for
// pre-provisioning from the terminal.
//   .build/release/Dictation --setup-local turbo
if let flagIndex = CommandLine.arguments.firstIndex(of: "--setup-local") {
    let name = CommandLine.arguments.count > flagIndex + 1 ? CommandLine.arguments[flagIndex + 1] : "turbo"
    guard let model = WhisperSetup.model(named: name) else {
        let known = WhisperSetup.catalog.map(\.name).joined(separator: " | ")
        print("Unknown model '\(name)'. Available: \(known)"); exit(1)
    }
    let sem = DispatchSemaphore(value: 0)
    var failed = false
    Task {
        do {
            try await WhisperSetup.run(model: model) { print("status: \($0)") }
            print("Setup complete.")
            print("  model dir: \(WhisperSetup.managedModelsDirectory.path)")
            print("  python:    \(WhisperSetup.managedPythonPath)")
        } catch {
            print("SETUP ERROR: \(error.localizedDescription)")
            failed = true
        }
        sem.signal()
    }
    sem.wait()
    exit(failed ? 1 : 0)
}

// Menu-bar agent entry point. `.accessory` keeps us out of the Dock and
// app switcher; all interaction happens through the status-bar item.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
