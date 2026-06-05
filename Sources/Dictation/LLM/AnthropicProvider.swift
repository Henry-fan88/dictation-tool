import Foundation

/// Talks to Claude's native Messages API (`/v1/messages`), which differs from
/// the OpenAI shape: `x-api-key` auth, an `anthropic-version` header, a
/// top-level `system` field, and a `content` block array in the response.
struct AnthropicProvider: LLMProvider {
    let baseURL: String
    let model: String
    let apiKey: String
    let temperature: Double
    let maxTokens: Int

    private struct Request: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let temperature: Double
        let messages: [ChatMessage]
    }
    private struct Response: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        let content: [Block]
    }

    func organize(transcript: String, systemPrompt: String) async throws -> String {
        let base = baseURL.isEmpty ? "https://api.anthropic.com/v1" : baseURL
        guard let url = URL(string: base.trimmingTrailingSlash + "/messages") else {
            throw DictationError.message("Invalid Anthropic base URL: \(base)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let payload = Request(
            model: model,
            max_tokens: maxTokens,
            system: systemPrompt,
            temperature: temperature,
            messages: [ChatMessage(role: "user", content: transcript)]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTP.check(response, data)

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.content.compactMap { $0.text }.joined()
        guard !text.isEmpty else {
            throw DictationError.message("Anthropic returned no text content")
        }
        return text
    }
}
