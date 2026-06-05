import Foundation

/// Organizes raw transcript text using an LLM. The `systemPrompt` is the main
/// knob users tune to control tone, formatting, and behavior.
protocol LLMProvider {
    func organize(transcript: String, systemPrompt: String) async throws -> String
}

/// Shared chat-style message shape used by the OpenAI-compatible providers.
struct ChatMessage: Codable {
    let role: String
    let content: String
}
