import AVFoundation
import Foundation

/// CXR carries control/HUD only. iOS HFP records the selected glasses microphone.
@MainActor
final class TottiHFPCapture {
    private var activeID: String?
    private var selectedUID: String?
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var startup: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var recentIDs: [String] = []
    private var lastAckAt = -Double.infinity
    private let send: ([String: Any]) -> Void
    private let relay: TottiVoiceRelay
    private let audio = AVAudioSession.sharedInstance()
    private var activated = false

    init(send: @escaping ([String: Any]) -> Void, relay: TottiVoiceRelay) {
        self.send = send; self.relay = relay
    }

    func handle(_ fields: [String: Any]) -> Bool {
        guard let type = fields["type"] as? String, type.hasPrefix("totti_mic_") else { return false }
        guard let id = fields["request_id"] as? String, !id.isEmpty, id.utf8.count <= 128 else { return true }
        switch type {
        case "totti_mic_start":
            if activeID == id { if recorder?.isRecording == true { acknowledge(id) }; return true }
            if recentIDs.contains(id) { return true }
            guard activeID == nil, !relay.isBusy else { reply("totti_error", id, "前の音声を処理中です。"); return true }
            activeID = id; lastAckAt = -Double.infinity
            startup = Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.start(id) }
                catch is CancellationError { }
                catch { if self.activeID == id { self.fail(error.localizedDescription) } }
            }
        case "totti_mic_stop":
            if activeID == id {
                if recorder?.isRecording == true { finish() }
                else { fail("Bluetoothマイクはまだ録音を開始していません。") }
            }
        case "totti_mic_cancel":
            if activeID == id { cleanup() }
            relay.cancelCaptured(id)
        default: break
        }
        return true
    }

    private func start(_ id: String) async throws {
        let permission: Bool
        switch audio.recordPermission {
        case .granted: permission = true
        case .denied: permission = false
        case .undetermined:
            permission = await withCheckedContinuation { continuation in
                audio.requestRecordPermission { continuation.resume(returning: $0) }
            }
        @unknown default: permission = false
        }
        try Task.checkCancellation()
        guard activeID == id else { return }
        guard permission else { throw Failure.message("iPhoneの設定でRokid Lyricsのマイク利用を許可してください。") }
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        try audio.setActive(true); activated = true
        // iOS can publish availableInputs after session activation.
        var ports = audio.availableInputs ?? []
        for _ in 0..<30 {
            if ports.contains(where: { $0.portType == .bluetoothHFP && Self.isGlassesName($0.portName) }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
            ports = audio.availableInputs ?? []
        }
        let selected = try TottiHFPInputPolicy.choose(ports.map(Self.describe))
        guard let port = ports.first(where: { $0.uid == selected.uid }) else { throw Failure.message("HFP入力が接続解除されました。") }
        selectedUID = selected.uid
        try audio.setPreferredInput(port)
        for _ in 0..<30 {
            if validRoute() { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
        guard activeID == id, validRoute() else { throw Failure.message("眼鏡のBluetoothマイクへの入力切替を確認できませんでした。") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("totti-hfp-\(UUID().uuidString).wav")
        fileURL = url
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false]
        let capture = try AVAudioRecorder(url: url, settings: settings)
        capture.isMeteringEnabled = true
        recorder = capture
        guard capture.prepareToRecord(), capture.record() else { throw Failure.message("HFP録音を開始できませんでした。") }
        guard validRoute() else { throw Failure.message("録音開始時に入力が眼鏡以外へ変わりました。") }
        acknowledge(id)
        reply("totti_capture_info", id, "HFP_INPUT \(selected.name) WAV=16000Hz/mono/PCM16")
        print("[TottiHFP] RECORD id=\(id) input=\(selected.name) uid=\(selected.uid)")
        startup = nil
        monitor = Task { @MainActor [weak self] in
            var heardSpeech = false, announced = false
            var lastSpeech: TimeInterval = 0
            var peakDB: Float = -160
            let began = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard let self, self.activeID == id, let recording = self.recorder else { return }
                guard self.validRoute() else { self.fail("録音中に眼鏡のBluetoothマイク接続が切れました。"); return }
                guard recording.isRecording else { self.fail("HFP録音が予期せず停止しました。"); return }
                recording.updateMeters()
                let level = recording.averagePower(forChannel: 0)
                peakDB = max(peakDB, level)
                let now = ProcessInfo.processInfo.systemUptime
                if !announced && recording.currentTime >= 0.15 {
                    announced = true
                    self.reply("totti_listening", id, "聞いています（眼鏡のBluetoothマイク）")
                }
                if recording.currentTime >= 0.15 && level >= -40 { heardSpeech = true; lastSpeech = now }
                if heardSpeech && now - lastSpeech >= 3 { self.finish(); return }
                if now - began >= 30 {
                    if heardSpeech { self.finish() }
                    else { self.fail("眼鏡のHFP入力で30秒間声を検出できませんでした（最大\(Int(peakDB))dB）。") }
                    return
                }
            }
        }
    }

    private static func isGlassesName(_ name: String) -> Bool {
        let value = name.lowercased(); return value.contains("rokid") || value.contains("glasses")
    }
    private static func describe(_ port: AVAudioSessionPortDescription) -> TottiHFPInputPolicy.Input {
        .init(uid: port.uid, name: port.portName, isHFP: port.portType == .bluetoothHFP)
    }
    private func validRoute() -> Bool {
        guard let uid = selectedUID else { return false }
        return TottiHFPInputPolicy.matchesActual(audio.currentRoute.inputs.map(Self.describe), selectedUID: uid)
    }
    private func acknowledge(_ id: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAckAt >= 10 else { return }
        lastAckAt = now; reply("totti_mic_ack", id, "start")
    }
    private func finish() {
        guard let id = activeID, let recording = recorder, let url = fileURL else { return }
        guard validRoute() else { fail("録音終了時の入力が眼鏡ではありません。"); return }
        recording.stop()
        do {
            let wav = try Data(contentsOf: url)
            let bytes = try TottiHFPWave.validate(wav)
            cleanup()
            reply("totti_processing", id, "iPhoneからAIへ送信中…")
            reply("totti_capture_info", id, "HFP_WAV_READY pcmBytes=\(bytes) wavBytes=\(wav.count)")
            relay.submitCaptured(id, wav: wav)
        } catch { fail("HFP録音ファイルの形式・長さを確認できませんでした: \(error)") }
    }
    func connectionLost() {
        if activeID != nil { fail("眼鏡との制御接続が切れました。") }
        relay.connectionLost()
    }
    private func fail(_ message: String) {
        guard let id = activeID else { return }
        print("[TottiHFP] ERROR id=\(id) \(message)")
        cleanup(); reply("totti_error", id, message)
    }
    private func cleanup() {
        startup?.cancel(); startup = nil; monitor?.cancel(); monitor = nil
        recorder?.stop(); recorder = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }; fileURL = nil
        if let id = activeID { recentIDs.append(id); if recentIDs.count > 32 { recentIDs.removeFirst() } }
        activeID = nil; selectedUID = nil
        if activated { try? audio.setActive(false, options: .notifyOthersOnDeactivation); activated = false }
    }
    private func reply(_ type: String, _ id: String, _ message: String) {
        send(["type": type, "request_id": id, "message": message])
    }
    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
    }
}
