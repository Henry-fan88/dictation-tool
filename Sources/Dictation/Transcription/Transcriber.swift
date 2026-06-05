import Foundation

/// Turns a recorded audio file into text. Implementations are selected from
/// config at runtime, so adding a new backend is a matter of conforming here.
protocol Transcriber {
    func transcribe(audioURL: URL) async throws -> String
}
