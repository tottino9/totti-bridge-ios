import AVFoundation
import Foundation

/// One voice-processing graph for both mic input and synthesized playback.
/// The same output graph supplies the echo canceller's playback reference.
@MainActor
final class TottiDuplexAudio {
    static let shared = TottiDuplexAudio()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var tapInstalled = false
    private var generation = UUID()
    private var drain = TottiPlaybackDrain()
    private var playbackConverter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var completed: (() -> Void)?
    var receive: ((Data) -> Void)?
    var failed: ((String) -> Void)?
    var isRunning: Bool { engine?.isRunning == true }

    func start() throws {
        if isRunning { return }
        stop()
        let graph = AVAudioEngine()
        engine = graph
        try graph.inputNode.setVoiceProcessingEnabled(true)
        let source = graph.inputNode.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let destination = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: destination) else {
            throw Failure.message("眼鏡の音声形式を変換できませんでした。")
        }
        let output = AVAudioPlayerNode()
        player = output
        graph.attach(output)
        graph.connect(output, to: graph.mainMixerNode, format: playbackFormat)
        let token = generation
        graph.inputNode.installTap(onBus: 0, bufferSize: 1024, format: source) { [weak self] input, _ in
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / source.sampleRate) + 64)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let result = converter.convert(to: pcm, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return input
            }
            if error != nil || result == .error {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.failed?("音声形式の変換に失敗しました。")
                }
                return
            }
            guard pcm.frameLength > 0, let samples = pcm.int16ChannelData?[0] else { return }
            let data = Data(bytes: samples, count: Int(pcm.frameLength) * 2)
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.receive?(data)
            }
        }
        tapInstalled = true
        graph.prepare()
        try graph.start()
    }

    func beginPlayback(completed: @escaping () -> Void) -> UUID {
        cancelPlayback()
        self.completed = completed
        return drain.token
    }
    func appendPlayback(_ input: AVAudioPCMBuffer, token: UUID) {
        guard token == drain.token, isRunning, let player else { return }
        if input.frameLength == 0 {
            if drain.markEnded(token) { finishPlayback() }
            return
        }
        if sourceFormat != input.format {
            sourceFormat = input.format
            playbackConverter = AVAudioConverter(from: input.format, to: playbackFormat)
        }
        guard let converter = playbackConverter,
              let output = AVAudioPCMBuffer(pcmFormat: playbackFormat,
                  frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate) + 64)) else {
            failed?("読み上げ音声の変換準備に失敗しました。")
            return
        }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard error == nil, result != .error else { failed?("読み上げ音声の変換に失敗しました。"); return }
        guard output.frameLength > 0 else { return }
        guard drain.enqueue(token) else { return }
        player.scheduleBuffer(output, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.drain.token == token else { return }
                if self.drain.played(token) { self.finishPlayback() }
            }
        }
        if !player.isPlaying { player.play() }
    }
    private func finishPlayback() {
        let callback = completed
        completed = nil
        callback?()
    }
    func cancelPlayback() {
        _ = drain.reset()
        completed = nil
        playbackConverter = nil; sourceFormat = nil
        player?.stop()
    }
    func stop() {
        generation = UUID()
        cancelPlayback()
        if let engine {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        }
        engine = nil; player = nil; tapInstalled = false
    }
    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
    }
}
