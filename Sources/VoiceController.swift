import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class VoiceController: ObservableObject {
    enum State: Equatable {
        case idle, recording, transcribing
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var levels: [Float] = []
    @Published private(set) var transcript: String?
    @Published private(set) var audioURL: URL?
    @Published private(set) var error: String?

    private var engine: AVAudioEngine?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionContinuation: CheckedContinuation<String, Error>?
    private var generation = 0

    func startRecording() async {
        guard state != .recording && state != .transcribing else { return }
        generation += 1
        let current = generation
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
        transcript = nil
        error = nil
        levels = []
        state = .recording

        let micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard generation == current else { return }
        guard micAllowed else { fail("Microphone access was denied. Enable it in System Settings > Privacy & Security > Microphone."); return }
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == current else { return }
        guard speechStatus == .authorized else { fail("Speech recognition access is unavailable or denied. Check System Settings > Privacy & Security > Speech Recognition."); return }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            fail("On-device speech recognition is unavailable for the current language.")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AgentDrop-\(UUID().uuidString).m4a")
        do {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.message("No microphone input is available.") }
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 128_000
            ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                do { try file.write(from: buffer) }
                catch {
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == current else { return }
                        self.cancel()
                        self.fail("Could not write the recording: \(error.localizedDescription)")
                    }
                    return
                }
                guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
                var sum: Float = 0
                for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
                let rms = sqrt(sum / Float(buffer.frameLength))
                let level = max(0, min(1, (20 * log10(max(rms, 0.000_001)) + 60) / 60))
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current else { return }
                    self.levels.append(level)
                    if self.levels.count > 60 { self.levels.removeFirst(self.levels.count - 60) }
                }
            }
            self.engine = engine
            audioURL = url
            try engine.start()
        } catch {
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
            audioURL = nil
            try? FileManager.default.removeItem(at: url)
            fail("Could not start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() async {
        guard state == .recording else { return }
        generation += 1
        let current = generation
        guard let engine, let url = audioURL else { state = .idle; return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        state = .transcribing
        do {
            guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                throw VoiceError.message("On-device speech recognition is unavailable for the current language.")
            }
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            let text = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                recognitionContinuation = continuation
                recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == current else { return }
                        if let error { self.finishRecognition(.failure(error)) }
                        else if let result, result.isFinal { self.finishRecognition(.success(result.bestTranscription.formattedString)) }
                    }
                }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    guard let self, self.generation == current else { return }
                    self.finishRecognition(.failure(VoiceError.message("Speech recognition timed out.")))
                }
            }
            guard generation == current else { return }
            transcript = text
            state = .idle
        } catch {
            guard generation == current else { return }
            fail("Transcription failed: \(error.localizedDescription)")
        }
    }

    func cancel() {
        generation += 1
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        finishRecognition(.failure(CancellationError()))
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
        transcript = nil
        error = nil
        levels = []
        state = .idle
    }

    private func finishRecognition(_ result: Result<String, Error>) {
        guard let continuation = recognitionContinuation else { return }
        recognitionContinuation = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        continuation.resume(with: result)
    }

    private func fail(_ message: String) {
        error = message
        state = .error(message)
    }

    private enum VoiceError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let message): return message }
        }
    }
}
