import Foundation

/// Cloud transcription via an OpenAI-compatible `/audio/transcriptions`
/// endpoint (OpenAI Whisper, Groq whisper-large-v3, etc.). Configurable base
/// URL + model so any compatible host works.
struct WhisperCloudTranscriber: Transcriber {
    let baseURL: String
    let model: String
    let apiKey: String
    let language: String?

    private struct Response: Decodable { let text: String }

    func transcribe(audioURL: URL) async throws -> String {
        guard let url = URL(string: baseURL.trimmingTrailingSlash + "/audio/transcriptions") else {
            throw DictationError.message("Invalid STT base URL: \(baseURL)")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioURL)

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }
        field("model", model)
        if let language, !language.isEmpty { field("language", language) }
        field("response_format", "json")

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.appendString("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTP.check(response, data)
        return try JSONDecoder().decode(Response.self, from: data).text
    }
}
