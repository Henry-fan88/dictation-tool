import Foundation

/// Talks to any OpenAI-compatible `/chat/completions` endpoint. Covers OpenAI,
/// Gemini (`…/v1beta/openai`), DeepSeek, Kimi/Moonshot, GLM/Zhipu, OpenRouter,
/// Groq, and local servers (llama.cpp, Ollama) — just point `baseURL` at them.
struct OpenAICompatibleProvider: LLMProvider {
    let baseURL: String
    let model: String
    let apiKey: String
    let temperature: Double
    let maxTokens: Int

    private struct Request: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
        let max_tokens: Int
    }
    private struct Response: Decodable {
        struct Choice: Decodable { let message: ChatMessage }
        let choices: [Choice]
    }

    func organize(transcript: String, systemPrompt: String) async throws -> String {
        guard let url = URL(string: baseURL.trimmingTrailingSlash + "/chat/completions") else {
            throw DictationError.message("Invalid LLM base URL: \(baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let payload = Request(
            model: model,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: transcript)
            ],
            temperature: temperature,
            max_tokens: maxTokens
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTP.check(response, data)

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw DictationError.message("LLM returned no choices")
        }
        return content
    }
}
