import Foundation

/// On-device transcription with a locally installed OpenAI Whisper (the
/// Python package), using model checkpoints already on disk. Spawns the
/// bundled `whisper_server.py` once; the helper keeps the model resident so
/// only the first dictation pays the model-load cost.
struct WhisperLocalTranscriber: Transcriber {
    let config: LocalSTTConfig

    func transcribe(audioURL: URL) async throws -> String {
        try await WhisperLocalServer.shared.transcribe(audioURL: audioURL, config: config)
    }
}

/// Owns the resident Python helper process. Lives across dictation runs (the
/// controller rebuilds transcribers per run, so the process is held by this
/// singleton) and restarts itself when the relevant config changes.
actor WhisperLocalServer {
    static let shared = WhisperLocalServer()

    private struct Settings: Equatable {
        var pythonPath: String
        var modelDir: String
        var model: String
        var device: String
    }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var settings: Settings?
    private var ready = false
    /// Incremented on every (re)start so callbacks from a dead process can't
    /// disturb its replacement.
    private var generation = 0
    private var nextToken = 1

    private var readyWaiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]

    /// First request after a (re)start reads the ~GB checkpoint from disk.
    private let readyTimeout: TimeInterval = 300
    private let transcribeTimeout: TimeInterval = 300

    // MARK: Public entry

    func transcribe(audioURL: URL, config: LocalSTTConfig) async throws -> String {
        // Empty paths mean "the app-managed install" (see WhisperSetup).
        let settings = Settings(
            pythonPath: WhisperSetup.effectivePythonPath(config),
            modelDir: WhisperSetup.effectiveModelDir(config),
            model: config.model,
            device: config.device
        )
        try ensureRunning(settings)
        try await awaitReady()

        let token = takeToken()
        var request: [String: Any] = ["id": token, "audio": audioURL.path]
        if let language = config.language, !language.isEmpty {
            request["language"] = language
        }
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)

        guard let stdinHandle, process?.isRunning == true else {
            throw DictationError.message("Local whisper process is not running")
        }
        try stdinHandle.write(contentsOf: line)

        expire(after: transcribeTimeout) { server in
            server.resumePending(token, with: .failure(DictationError.message(
                "Local whisper transcription timed out")))
        }
        return try await withCheckedThrowingContinuation { pending[token] = $0 }
    }

    // MARK: Process lifecycle

    private func ensureRunning(_ requested: Settings) throws {
        if let process, process.isRunning, settings == requested { return }
        stop()
        try start(requested)
    }

    private func start(_ requested: Settings) throws {
        guard FileManager.default.isExecutableFile(atPath: requested.pythonPath) else {
            throw DictationError.message(
                "Python for local Whisper not found at \(requested.pythonPath) — run the setup again or set transcription.local.pythonPath")
        }
        guard FileManager.default.fileExists(atPath: requested.modelDir) else {
            throw DictationError.message(
                "Whisper model folder not found at \(requested.modelDir) — run the setup again or set transcription.local.modelDir")
        }
        guard let script = Bundle.module.url(forResource: "whisper_server", withExtension: "py") else {
            throw DictationError.message("whisper_server.py missing from app bundle")
        }

        generation += 1
        let gen = generation

        let process = Process()
        process.executableURL = URL(fileURLWithPath: requested.pythonPath)
        process.arguments = [
            "-u", script.path,
            "--model", requested.model,
            "--model-dir", requested.modelDir,
            "--device", requested.device,
        ]

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        process.terminationHandler = { proc in
            Task { await WhisperLocalServer.shared.processExited(gen, status: proc.terminationStatus) }
        }

        Log.write("local whisper: starting \(requested.model) (\(requested.device)) via \(requested.pythonPath)")
        try process.run()

        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        self.settings = requested
        self.ready = false

        let stdoutHandle = stdout.fileHandleForReading
        Task {
            do {
                for try await line in stdoutHandle.bytes.lines {
                    await WhisperLocalServer.shared.handleOutput(line, generation: gen)
                }
            } catch {}
            await WhisperLocalServer.shared.processExited(gen, status: nil)
        }

        let stderrHandle = stderr.fileHandleForReading
        Task {
            do {
                for try await line in stderrHandle.bytes.lines {
                    Log.write("local whisper: \(line)")
                }
            } catch {}
        }
    }

    private func stop() {
        try? stdinHandle?.close()
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        process = nil
        stdinHandle = nil
        settings = nil
        ready = false
        failEverything(DictationError.message("Local whisper process was restarted"))
    }

    private func processExited(_ gen: Int, status: Int32?) {
        guard gen == generation, process != nil else { return }
        let detail = status.map { " (exit \($0))" } ?? ""
        Log.write("local whisper: process exited\(detail)")
        process = nil
        stdinHandle = nil
        settings = nil
        ready = false
        failEverything(DictationError.message(
            "Local whisper process exited\(detail) — see \(Log.url.path)"))
    }

    // MARK: Helper output

    private func handleOutput(_ line: String, generation gen: Int) {
        guard gen == generation else { return }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            Log.write("local whisper: unparseable output: \(line.prefix(200))")
            return
        }

        if obj["event"] as? String == "ready" {
            ready = true
            let waiters = readyWaiters
            readyWaiters = [:]
            waiters.values.forEach { $0.resume() }
            return
        }

        guard let id = obj["id"] as? Int else { return }
        if let text = obj["text"] as? String {
            resumePending(id, with: .success(text))
        } else if let message = obj["error"] as? String {
            resumePending(id, with: .failure(DictationError.message("Local whisper: \(message)")))
        }
    }

    // MARK: Waiting & bookkeeping

    private func awaitReady() async throws {
        if ready { return }
        let token = takeToken()
        expire(after: readyTimeout) { server in
            if let cont = server.readyWaiters.removeValue(forKey: token) {
                cont.resume(throwing: DictationError.message(
                    "Timed out waiting for the local Whisper model to load — see \(Log.url.path)"))
            }
        }
        try await withCheckedThrowingContinuation { readyWaiters[token] = $0 }
    }

    private func resumePending(_ id: Int, with result: Result<String, Error>) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(with: result)
    }

    private func failEverything(_ error: Error) {
        let waiters = readyWaiters
        readyWaiters = [:]
        waiters.values.forEach { $0.resume(throwing: error) }
        let requests = pending
        pending = [:]
        requests.values.forEach { $0.resume(throwing: error) }
    }

    private func takeToken() -> Int {
        defer { nextToken += 1 }
        return nextToken
    }

    /// Run `action` on this actor after a delay; used as a watchdog that
    /// resumes a still-pending continuation with a timeout error.
    private func expire(after seconds: TimeInterval, _ action: @escaping @Sendable (isolated WhisperLocalServer) -> Void) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            action(self)
        }
    }
}
