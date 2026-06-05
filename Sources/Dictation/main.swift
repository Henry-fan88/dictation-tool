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

// Menu-bar agent entry point. `.accessory` keeps us out of the Dock and
// app switcher; all interaction happens through the status-bar item.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
