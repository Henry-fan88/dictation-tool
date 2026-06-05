import AVFoundation

/// Captures microphone audio with AVAudioEngine and writes a 16 kHz mono WAV —
/// the format both Whisper-style APIs and SFSpeechRecognizer are happy with.
final class AudioRecorder {

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var currentURL: URL?

    private(set) var isRecording = false

    /// Begin recording to a fresh temp file. Caller must hold mic permission.
    func start() throws {
        guard !isRecording else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw DictationError.message("No audio input available (check microphone permission)")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let audioFile = try AVAudioFile(forWriting: url, settings: settings)
        // `processingFormat` is the (float) format AVAudioFile expects buffers
        // in; it transparently down-converts to 16-bit on disk.
        let processing = audioFile.processingFormat

        self.file = audioFile
        self.currentURL = url
        self.targetFormat = processing
        self.converter = AVAudioConverter(from: inputFormat, to: processing)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stop recording and return the WAV file URL (nil if nothing was recorded).
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return currentURL }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false

        let url = currentURL
        file = nil        // closes/flushes the file
        converter = nil
        targetFormat = nil
        return url
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let file, let converted = convert(buffer) else { return }
        do {
            try file.write(from: converted)
        } catch {
            NSLog("Dictation: audio write failed: %@", "\(error)")
        }
    }

    /// Resample/downmix one input buffer to the file's processing format.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let targetFormat else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 0.5)
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            if let error { NSLog("Dictation: convert failed: %@", "\(error)") }
            return nil
        }
        return output
    }
}
