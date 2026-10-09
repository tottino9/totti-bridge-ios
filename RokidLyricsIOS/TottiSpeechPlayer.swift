import AVFoundation
import Foundation

/// Keeps speech alive independently of the HTTP task. Playback uses the iPhone's
/// selected Bluetooth audio output; CXR data connectivity alone is insufficient.
@MainActor
final class TottiSpeechPlayer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    private var report: ((String, String) -> Void)?
    private var requestID = ""
    private var startTimeout: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    func speak(_ text: String, requestID: String, report: @escaping (String, String) -> Void) {
        guard current == nil else {
            report("totti_audio_error", "前の回答を読み上げ中です。")
            return
        }
        guard let voice = AVSpeechSynthesisVoice(language: "ja-JP") else {
            report("totti_audio_error", "iPhoneの日本語音声を利用できません。")
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            // Matches the existing background keep-alive session. Do not deactivate
            // this shared session when speech finishes.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            report("totti_audio_error", "音声出力の準備失敗: \(error.localizedDescription)")
            return
        }
        let outputs = session.currentRoute.outputs
        let route = outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        print("[TottiAudio] route id=\(requestID) output=\(route) volume=\(session.outputVolume)")
        report("totti_audio_status", "出力先: \(route) / 音量: \(session.outputVolume)")
        guard outputs.contains(where: { $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP }) else {
            report("totti_audio_error", "Bluetooth音声出力が未選択です。iPhoneの再生出力先をRokidにしてください。")
            return
        }
        self.requestID = requestID
        self.report = report
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        current = utterance
        print("[TottiAudio] requested id=\(requestID)")
        synthesizer.speak(utterance)
        startTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard let self, self.current != nil else { return }
            self.finish(type: "totti_audio_error", message: "読み上げ開始を15秒以内に確認できませんでした。")
            self.synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func finish(type: String, message: String) {
        startTimeout?.cancel()
        startTimeout = nil
        print("[TottiAudio] \(type) id=\(requestID) \(message)")
        report?(type, message)
        current = nil
        report = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.current === utterance else { return }
            self.startTimeout?.cancel()
            self.startTimeout = nil
            print("[TottiAudio] started id=\(self.requestID)")
            self.report?("totti_audio_status", "読み上げ開始（聞こえたかは実機で確認）")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.current === utterance else { return }
            self.finish(type: "totti_audio_status", message: "読み上げ処理完了（聞こえたかは実機で確認）")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.current === utterance else { return }
            self.finish(type: "totti_audio_error", message: "読み上げが中断されました。")
        }
    }
}
