import AppKit
import CryptoKit

/// One Whisper checkpoint the app knows how to download. URLs are the
/// official ones from the `openai-whisper` package (`whisper._MODELS`); the
/// directory component of each URL is the file's SHA-256, which we verify.
struct WhisperModel: Sendable {
    let name: String      // whisper model name passed to load_model()
    let fileName: String  // checkpoint file name load_model() looks for
    let note: String      // shown in the first-run picker
    let bytes: Int64
    let url: URL

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// First-run bootstrap for the `local` transcription backend. Open-source
/// users won't have a Whisper checkpoint or a Python environment with
/// `openai-whisper`, so the app provisions both into an app-managed folder
/// (`~/Library/Application Support/Dictation`) — downloaded once, reused
/// forever. Config paths left empty mean "use the managed locations"; users
/// with an existing install point `pythonPath`/`modelDir` at it instead.
enum WhisperSetup {

    static let catalog: [WhisperModel] = [
        model("tiny", "fastest, lowest accuracy", 75_572_083,
              "65147644a518d12f04e32d6f3b26facc3f8dd46e5390956a9424a650c0ce22b9/tiny.pt"),
        model("base", "fast and light", 145_262_807,
              "ed3a0b6b1c0edf879ad9b11b1af5a0e6ab5db9205f891f668f8b0e6c6326e34e/base.pt"),
        model("small", "good speed/accuracy balance", 483_617_219,
              "9ecf779972d90ba49c06d968637d720dd632c55bbf19d441fb42bf17a411e794/small.pt"),
        model("medium", "high accuracy, slower", 1_528_008_539,
              "345ae4da62f9b3d59415adc60127b97c714f32e89e936602e85993674d08dcb1/medium.pt"),
        model("turbo", "best accuracy per second — recommended", 1_617_941_637,
              "aff26ae408abcba5fbf8813c21e62b0941638c5f6eebfb145be0c9839262a19a/large-v3-turbo.pt"),
        model("large-v3", "maximum accuracy, slowest", 3_087_371_615,
              "e5b1a55b89c1367dacf97e3e19bfd829a01529dbfdeefa8caeb59b3f1b81dadb/large-v3.pt"),
    ]

    private static func model(_ name: String, _ note: String, _ bytes: Int64, _ path: String) -> WhisperModel {
        WhisperModel(
            name: name,
            fileName: String(path.split(separator: "/").last!),
            note: note,
            bytes: bytes,
            url: URL(string: "https://openaipublic.azureedge.net/main/whisper/models/\(path)")!
        )
    }

    static func model(named name: String) -> WhisperModel? {
        catalog.first { $0.name == name }
    }

    // MARK: Managed locations

    /// App-owned data folder. `DICTATION_DATA_DIR` overrides it (used by tests).
    static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["DICTATION_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictation", isDirectory: true)
    }

    static var managedModelsDirectory: URL {
        dataDirectory.appendingPathComponent("models", isDirectory: true)
    }

    static var managedEnvDirectory: URL {
        dataDirectory.appendingPathComponent("python-env", isDirectory: true)
    }

    static var managedPythonPath: String {
        managedEnvDirectory.appendingPathComponent("bin/python3").path
    }

    /// Empty config paths resolve to the app-managed locations.
    static func effectivePythonPath(_ config: LocalSTTConfig) -> String {
        config.pythonPath.isEmpty ? managedPythonPath : config.pythonPath
    }

    static func effectiveModelDir(_ config: LocalSTTConfig) -> String {
        config.modelDir.isEmpty ? managedModelsDirectory.path : config.modelDir
    }

    // MARK: Status

    /// Cheap check used on every fn-press. Models we don't know (e.g. "tiny.en")
    /// are assumed present — whisper itself downloads unknown-but-valid names.
    static func isComplete(_ config: LocalSTTConfig) -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: effectivePythonPath(config)) else { return false }
        guard let model = model(named: config.model) else { return true }
        let checkpoint = URL(fileURLWithPath: effectiveModelDir(config))
            .appendingPathComponent(model.fileName)
        return fm.fileExists(atPath: checkpoint.path)
    }

    // MARK: First-run dialog

    /// Modal model picker. Returns nil if the user cancels.
    @MainActor
    static func promptForModel(defaultName: String) -> WhisperModel? {
        let alert = NSAlert()
        alert.messageText = "Set Up Local Whisper"
        alert.informativeText = """
        Local transcription needs a one-time setup. The model you choose is \
        downloaded to \(managedModelsDirectory.path) and reused from there; if \
        needed, a private Python environment with openai-whisper is installed \
        alongside it. Progress is shown in the menu bar.
        """
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 25), pullsDown: false)
        for entry in catalog {
            popup.addItem(withTitle: "\(entry.name) — \(entry.note) (\(entry.sizeLabel))")
        }
        let defaultIndex = catalog.firstIndex { $0.name == defaultName }
            ?? catalog.firstIndex { $0.name == "turbo" } ?? 0
        popup.selectItem(at: defaultIndex)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Download & Set Up")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return catalog[popup.indexOfSelectedItem]
    }

    // MARK: Setup execution

    /// Provision whatever is missing: download + verify the checkpoint, then
    /// create the managed Python environment if no usable one exists. Safe to
    /// re-run; finished pieces are skipped. `progress` may be called from any
    /// queue.
    static func run(model: WhisperModel, progress: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: managedModelsDirectory, withIntermediateDirectories: true)

        let destination = managedModelsDirectory.appendingPathComponent(model.fileName)
        if !fm.fileExists(atPath: destination.path) {
            Log.write("setup: downloading \(model.url.absoluteString)")
            let downloaded = try await Downloader.fetch(model.url) { fraction in
                progress("Downloading \(model.name) model (\(model.sizeLabel))… \(Int(fraction * 100))%")
            }
            progress("Verifying \(model.name) checksum…")
            let expected = model.url.deletingLastPathComponent().lastPathComponent
            let actual = try sha256Hex(of: downloaded)
            guard actual == expected else {
                try? fm.removeItem(at: downloaded)
                throw DictationError.message("Downloaded \(model.name) model failed checksum verification — try again")
            }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: downloaded, to: destination)
            Log.write("setup: model saved to \(destination.path)")
        }

        let python = managedPythonPath
        if !fm.isExecutableFile(atPath: python) {
            progress("Creating Python environment…")
            guard let basePython = findSystemPython() else {
                throw DictationError.message(
                    "No python3 found — install the Xcode Command Line Tools (xcode-select --install) or Homebrew Python, then retry")
            }
            Log.write("setup: creating venv at \(managedEnvDirectory.path) with \(basePython)")
            try await runLogged(basePython, ["-m", "venv", managedEnvDirectory.path])
        }
        if try await !pythonHasWhisper(python) {
            progress("Installing openai-whisper (this can take a few minutes)…")
            try await runLogged(python, ["-m", "pip", "install", "--upgrade", "pip", "wheel"])
            try await runLogged(python, ["-m", "pip", "install", "--upgrade", "openai-whisper"])
            guard try await pythonHasWhisper(python) else {
                throw DictationError.message(
                    "openai-whisper installed but cannot be imported — see \(Log.url.path)")
            }
        }
        progress("Local Whisper ready")
        Log.write("setup: complete (model=\(model.name), python=\(python))")
    }

    // MARK: Pieces

    private static func findSystemPython() -> String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func pythonHasWhisper(_ python: String) async throws -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python) else { return false }
        return (try? await runLogged(python, ["-c", "import whisper"])) != nil
    }

    /// Run a process to completion, streaming its output to the app log.
    private static func runLogged(_ launchPath: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let outputHandle = output.fileHandleForReading
        Task {
            do {
                for try await line in outputHandle.bytes.lines where !line.isEmpty {
                    Log.write("setup: \(line)")
                }
            } catch {}
        }

        try process.run()
        await withCheckedContinuation { cont in
            process.terminationHandler = { _ in cont.resume() }
        }
        guard process.terminationStatus == 0 else {
            let command = ([launchPath] + arguments).joined(separator: " ")
            throw DictationError.message("Setup step failed (exit \(process.terminationStatus)): \(command) — see \(Log.url.path)")
        }
    }

    private static func sha256Hex(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Download with progress callbacks. `URLSession.download(for:)` has no
/// progress hooks, so this wraps the delegate-based API in async/await.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    static func fetch(_ url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let downloader = Downloader(onProgress: onProgress)
        return try await downloader.start(url)
    }

    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var movedTo: URL?
    private var lastReportedPercent = -1

    private init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    private func start(_ url: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
        if percent != lastReportedPercent {
            lastReportedPercent = percent
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this method returns — move it now.
        let holding = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-download-\(UUID().uuidString).pt")
        do {
            try FileManager.default.moveItem(at: location, to: holding)
            movedTo = holding
        } catch {
            movedTo = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { continuation = nil }
        if let error {
            continuation?.resume(throwing: error)
            return
        }
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let movedTo { try? FileManager.default.removeItem(at: movedTo) }
            continuation?.resume(throwing: DictationError.message("Model download failed: HTTP \(http.statusCode)"))
            return
        }
        guard let movedTo else {
            continuation?.resume(throwing: DictationError.message("Model download failed: could not save file"))
            return
        }
        continuation?.resume(returning: movedTo)
    }
}
