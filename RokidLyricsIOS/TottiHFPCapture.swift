#if !TOTTI_EXPERIMENTAL_DUPLEX
import AVFoundation
import Foundation
import UIKit

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
    private var audioOwner: String?
    private var startupStage = "idle"

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
            guard relay.acceptSession(fields["session_id"] as? String ?? "legacy") else {
                send(["type": "totti_session_end", "request_id": id])
                return true
            }
            relay.noteCaptureRequest()
            activeID = id; lastAckAt = -Double.infinity
            startupStage = "permission"
            if audio.recordPermission == .undetermined {
                reply("totti_status", id, "iPhoneの画面でマイクの利用を許可してください。")
            }
            startup = Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.start(id) }
                catch is CancellationError { }
                catch {
                    if self.activeID == id {
                        let ns = error as NSError
                        self.fail("音声準備失敗 [\(self.startupStage)] \(ns.domain)/\(ns.code): \(error.localizedDescription)")
                    }
                }
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
        guard UIApplication.shared.applicationState == .active else {
            throw Failure.message("iPhoneでトッティのアプリを前面に開いてから開始してください。")
        }
        let owner = "record:" + id
        guard TottiAudioGate.acquire(owner) else {
            throw Failure.message("前の音声処理の終了を待ってから開始してください。")
        }
        audioOwner = owner
        if !TottiAudioGate.conversationActive {
            startupStage = "category"
            try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            startupStage = "activate"
            try audio.setActive(true)
            TottiAudioGate.retainConversation()
        }
        startupStage = "selectHFP"
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
        startupStage = "route"
        if !validRoute() { try audio.setPreferredInput(port) }
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
        startupStage = "createRecorder"
        let capture = try AVAudioRecorder(url: url, settings: settings)
        capture.isMeteringEnabled = true
        recorder = capture
        startupStage = "prepareToRecord"
        guard capture.prepareToRecord() else {
            throw Failure.message("録音準備が拒否されました。\(audioDiagnostic)")
        }
        startupStage = "record"
        guard capture.record() else {
            throw Failure.message("録音開始が拒否されました。\(audioDiagnostic)")
        }
        startupStage = "recording"
        guard validRoute() else { throw Failure.message("録音開始時に入力が眼鏡以外へ変わりました。") }
        reply("totti_capture_info", id, "HFP_INPUT \(selected.name) WAV=16000Hz/mono/PCM16")
        print("[TottiHFP] RECORD id=\(id) input=\(selected.name) uid=\(selected.uid)")
        startup = nil
        monitor = Task { @MainActor [weak self] in
            var heardSpeech = false, announced = false
            var lastSpeech: TimeInterval = 0
            var peakDB: Float = -160
            var began = ProcessInfo.processInfo.systemUptime
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
                    self.acknowledge(id)
                }
                if recording.currentTime >= 0.15 && level >= -40 { heardSpeech = true; lastSpeech = now }
                if heardSpeech && now - lastSpeech >= TottiDeliveryPolicy.silenceSeconds { self.finish(); return }
                if now - began >= 30 {
                    if heardSpeech { self.finish() }
                    else if !self.relay.hasAskedToEnd {
                        self.cleanup(keepAudio: true)
                        self.relay.promptAfterSilence(id)
                    } else {
                        // Stay listening silently after the single end-of-conversation prompt.
                        // Route and recorder health checks above remain active.
                        // Roll the silent recording file to bound disk use. No network
                        // request, HUD message, or audio-session activation is repeated.
                        recording.stop()
                        guard recording.prepareToRecord(), recording.record() else {
                            self.fail("待機中の録音を再開できませんでした。")
                            return
                        }
                        began = now
                        continue
                    }
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
        lastAckAt = now
        send(["type": "totti_listening", "request_id": id, "message": "話しかけてください",
              "input_name": audio.currentRoute.inputs.map { $0.portName }.joined(separator: ","),
              "silence_seconds": TottiDeliveryPolicy.silenceSeconds,
              "resume_ms": relay.millisecondsSinceCompletion])
    }
    private func finish() {
        guard let id = activeID, let recording = recorder, let url = fileURL else { return }
        guard validRoute() else { fail("録音終了時の入力が眼鏡ではありません。"); return }
        recording.stop()
        do {
            let wav = try Data(contentsOf: url)
            let bytes = try TottiHFPWave.validate(wav)
            cleanup(keepAudio: true)
            reply("totti_capture_info", id, "HFP_WAV_READY pcmBytes=\(bytes) wavBytes=\(wav.count)")
            relay.submitCaptured(id, wav: wav)
        } catch { fail("HFP録音ファイルの形式・長さを確認できませんでした: \(error)") }
    }
    func controlPaused(reason: String?) {
        let value = reason ?? "unknown"
        if TottiControlPausePolicy.mayContinueHFP(reason: reason) {
            if let id = activeID {
                reply("totti_capture_info", id, "CXR_PAUSED reason=\(value) HFP_ROUTE_MONITORED")
            }
            return
        }
        connectionLost(reason: "sessionPaused/" + value)
    }
    private var audioDiagnostic: String {
        let input = audio.currentRoute.inputs.map { "\($0.portName):\($0.portType.rawValue)" }.joined(separator: ",")
        return "category=\(audio.category.rawValue) rate=\(audio.sampleRate) input=\(input)"
    }
    func connectionLost(reason: String = "linkDisconnected") {
        if activeID != nil { fail("音声処理を停止しました [\(reason)]") }
        relay.connectionLost()
    }
    private func fail(_ message: String) {
        guard let id = activeID else { return }
        if relay.sessionEnded { cleanup(); return }
        print("[TottiHFP] ERROR id=\(id) \(message)")
        cleanup(); reply("totti_error", id, message)
    }
    private func cleanup(keepAudio: Bool = false) {
        startup?.cancel(); startup = nil; monitor?.cancel(); monitor = nil
        recorder?.stop(); recorder = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }; fileURL = nil
        if let id = activeID { recentIDs.append(id); if recentIDs.count > 32 { recentIDs.removeFirst() } }
        activeID = nil; selectedUID = nil
        if !keepAudio { TottiConversationAudio.end() }
        if let owner = audioOwner { TottiAudioGate.release(owner) }
        audioOwner = nil
        startupStage = "idle"
    }
    private func reply(_ type: String, _ id: String, _ message: String) {
        send(["type": type, "request_id": id, "message": message])
    }
    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
    }
}
#else
import AVFoundation
import Foundation
import UIKit

@MainActor
final class TottiHFPCapture {
    private var activeID: String?
    private var selectedUID: String?
    private var startup: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var recentIDs: [String] = []
    private var lastAckAt = -Double.infinity
    private let send: ([String: Any]) -> Void
    private let relay: TottiVoiceRelay
    private let audio = AVAudioSession.sharedInstance()
    private let duplex = TottiDuplexAudio.shared
    private var startupStage = "idle"
    private var readyAcknowledged = false
    private var readiness = TottiInputReadiness()
    private var inputEpoch = 0
    private var segmenter = TottiDuplexSegmenter()
    private var bargeWindow = false
    private var handoffListening = false
    private var handoffWavs: [Data] = []
    private var lastControlID: String?
    private var controlSessionID: String?
    private var pendingAudioFailure: (session:String,message:String)?
    private var began = 0.0
    private var lastPCM = 0.0
    private var generation = UUID()

    init(send: @escaping ([String: Any]) -> Void, relay: TottiVoiceRelay) {
        self.send = send; self.relay = relay
        relay.onSpeechPlaybackChanged = { [weak self] playing in
            guard let self else { return }
            self.bargeWindow = playing
            if playing {
                // Keep near-end evidence when TTS completion and the next control request race.
                self.handoffListening = true
                if self.readyAcknowledged, self.duplex.isRunning, self.validRoute(),
                   ProcessInfo.processInfo.systemUptime - self.lastPCM < 0.5,
                   let id = self.relay.speakingRequestID {
                    self.send(["type":"totti_listening", "request_id":id,
                        "message":"話しかけてください", "barge_in":true, "input_epoch":self.inputEpoch])
                }
            }
        }
    }
    func handle(_ fields: [String: Any]) -> Bool {
        guard let type = fields["type"] as? String, type.hasPrefix("totti_mic_") else { return false }
        guard let id = fields["request_id"] as? String, !id.isEmpty, id.utf8.count <= 128 else { return true }
        switch type {
        case "totti_mic_start":
            if activeID == id { if readyAcknowledged { acknowledge(id) }; return true }
            if recentIDs.contains(id) { return true }
            guard activeID == nil, !relay.isBusy else { reply("totti_error", id, "前の音声を処理中です。"); return true }
            guard relay.acceptSession(fields["session_id"] as? String ?? "legacy") else {
                send(["type":"totti_session_end", "request_id":id]); return true
            }
            relay.noteCaptureRequest()
            let incomingSession=fields["session_id"] as? String ?? "legacy"
            if let failure=pendingAudioFailure {
                pendingAudioFailure=nil
                if failure.session==incomingSession {
                    // A graph failure between turns has no active request to
                    // notify. Deliver it on the next owned request, not an old ID
                    // that Android has already completed and will ignore.
                    recentIDs.append(id)
                    if recentIDs.count>32 {recentIDs.removeFirst()}
                    reply("totti_error",id,"音声処理を停止しました: "+failure.message)
                    return true
                }
            }
            controlSessionID=incomingSession
            lastControlID = id
            activeID = id; lastAckAt = -Double.infinity; readyAcknowledged = false; readiness = TottiInputReadiness()
            began = ProcessInfo.processInfo.systemUptime
            startup = Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.start(id) }
                catch is CancellationError { }
                catch { if self.activeID == id { self.fail("音声準備失敗 [\(self.startupStage)] \(error.localizedDescription)") } }
            }
        case "totti_mic_stop":
            if activeID == id { consume(segmenter.finish()) }
            else if relay.speakingRequestID == id { relay.interruptSpeech() }
        case "totti_mic_cancel":
            if activeID == id { cleanup(keepAudio:false) }
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
        guard UIApplication.shared.applicationState == .active else {
            throw Failure.message("iPhoneでトッティのアプリを前面に開いてから開始してください。")
        }
        let owner = "record:" + id
        guard TottiAudioGate.acquire(owner) else {
            throw Failure.message("前の音声処理の終了を待ってから開始してください。")
        }
        defer { TottiAudioGate.release(owner) }
        if !TottiAudioGate.conversationActive {
            startupStage = "category"
            try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            startupStage = "activate"
            try audio.setActive(true)
            TottiAudioGate.retainConversation()
        }
        startupStage = "selectHFP"
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
        startupStage = "route"
        if !validRoute() { try audio.setPreferredInput(port) }
        for _ in 0..<30 {
            if validRoute() { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
        guard activeID == id, validRoute() else { throw Failure.message("眼鏡のBluetoothマイクへの入力切替を確認できませんでした。") }
        startupStage = "voiceProcessing"
        let token = generation
        duplex.inputInvalidated = { [weak self] in
            guard let self, self.generation == token else { return }
            if self.segmenter.speaking {
                self.audioFailed(reason:"AUDIO_FORMAT_CHANGED_DURING_CAPTURE")
                return
            }
            self.readyAcknowledged = false
            self.inputEpoch += 1
            self.readiness = TottiInputReadiness()
            self.lastPCM = ProcessInfo.processInfo.systemUptime
            self.lastAckAt = -Double.infinity
            if let id = self.activeID ?? self.relay.speakingRequestID {
                self.send(["type":"totti_input_preparing", "request_id":id,
                    "message":"音声入力を準備しています…", "input_epoch":self.inputEpoch])
            }
        }
        duplex.receive = { [weak self] data in
            guard let self, self.generation == token else { return }
            self.received(data)
        }
        duplex.failed = { [weak self] message in
            guard let self, self.generation == token else { return }
            self.audioFailed(reason:message)
        }
        try duplex.start()
        guard validRoute() else { throw Failure.message("録音開始時に入力が眼鏡以外へ変わりました。") }
        lastPCM = ProcessInfo.processInfo.systemUptime
        startup = nil
        if monitor == nil {
            monitor = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                    guard let self, self.generation == token else { return }
                    if self.relay.sessionEnded { self.cleanup(keepAudio:false); return }
                    let now = ProcessInfo.processInfo.systemUptime
                    guard self.pollInputHealth(now:now) else { continue }
                    if let id = self.activeID, !self.segmenter.speaking, now-self.began >= 30 {
                        if !self.relay.hasAskedToEnd {
                            self.cleanup(keepAudio:true)
                            self.relay.promptAfterSilence(id)
                        } else { self.began = now }
                    }
                }
            }
        }
    }
    // Shared by the real monitor and deterministic ordering tests.
    @discardableResult
    func pollInputHealth(now:Double) -> Bool {
        guard validRoute() else { audioFailed(reason:"HFP_ROUTE_CHANGED"); return false }
        guard duplex.inputAvailable(now:now) else { return false }
        guard now-lastPCM < 5 else { audioFailed(reason:"HFP_PCM_TIMEOUT"); return false }
        return true
    }
    private func received(_ data: Data) {
        // Empty/odd fragments are not microphone progress and cannot refresh watchdog.
        guard data.count >= 2, data.count.isMultiple(of: 2) else { return }
        if relay.sessionEnded { cleanup(keepAudio:false); return }
        guard validRoute() else { audioFailed(reason:"HFP_ROUTE_CHANGED"); return }
        guard duplex.inputAvailable() else { return }
        lastPCM = ProcessInfo.processInfo.systemUptime
        if let id = activeID {
            if readiness.accept(pcmBytes:data.count) {
                readyAcknowledged = true
                acknowledge(id)
                if !handoffWavs.isEmpty {
                    let wav = handoffWavs.removeFirst(); submit(id,wav:wav); return
                }
            }
        }
        guard activeID != nil || bargeWindow || handoffListening || segmenter.speaking else {
            segmenter = TottiDuplexSegmenter(); return
        }
        consume(segmenter.append(data))
    }
    private func consume(_ events: [TottiDuplexSegmenter.Event]) {
        for event in events {
            switch event {
            case .began:
                if bargeWindow {
                    // Preserve the segment's pre-roll across the Android turn handoff.
                    bargeWindow = false
                    relay.interruptSpeech()
                }
            case .ended(let wav):
                if let id = activeID { submit(id,wav:wav) }
                else {
                    guard handoffWavs.count < 4 else {
                        let id = lastControlID
                        cleanup(keepAudio:false)
                        if let id { reply("totti_error",id,"音声の受け渡し待ちが上限に達したため停止しました。") }
                        return
                    }
                    handoffWavs.append(wav)
                }
            }
        }
    }
    private func acknowledge(_ id:String) {
        let now=ProcessInfo.processInfo.systemUptime
        guard now-lastAckAt >= 10 else { return }
        lastAckAt=now
        send(["type":"totti_listening", "request_id":id, "message":"話しかけてください", "input_epoch":inputEpoch])
    }
    private func submit(_ id:String,wav:Data) {
        guard activeID == id else { return }
        cleanup(keepAudio:true)
        reply("totti_processing",id,"聞き取っています…")
        relay.submitCaptured(id,wav:wav)
    }
    private static func isGlassesName(_ name: String) -> Bool {
        let value=name.lowercased(); return value.contains("rokid") || value.contains("glasses")
    }
    private static func describe(_ port: AVAudioSessionPortDescription) -> TottiHFPInputPolicy.Input {
        .init(uid:port.uid,name:port.portName,isHFP:port.portType == .bluetoothHFP)
    }
    private func validRoute() -> Bool {
        guard let uid=selectedUID else { return false }
        return TottiHFPInputPolicy.matchesActual(audio.currentRoute.inputs.map(Self.describe),selectedUID:uid)
    }
    func controlPaused(reason:String?) {
        if !TottiControlPausePolicy.mayContinueHFP(reason:reason) { connectionLost(reason:reason ?? "unknown") }
    }
    func connectionLost(reason:String = "linkDisconnected") {
        pendingAudioFailure=nil
        controlSessionID=nil
        if let id=activeID { reply("totti_error",id,"音声処理を停止しました [\(reason)]") }
        cleanup(keepAudio:false)
        relay.connectionLost()
    }
    private func audioFailed(reason:String) {
        if activeID==nil,!relay.isBusy,let session=controlSessionID {
            pendingAudioFailure=(session,reason)
        }
        if let id=activeID { reply("totti_error",id,"音声処理を停止しました [\(reason)]") }
        cleanup(keepAudio:false)
        relay.audioFailed(reason)
    }
    private func fail(_ message:String) {
        let id=activeID
        cleanup(keepAudio:false)
        if let id { reply("totti_error",id,message) }
    }
    private func cleanup(keepAudio:Bool) {
        startup?.cancel(); startup=nil
        if let id=activeID { recentIDs.append(id); if recentIDs.count>32 { recentIDs.removeFirst() } }
        activeID=nil
        if !keepAudio {
            generation=UUID(); monitor?.cancel(); monitor=nil
            bargeWindow=false; handoffListening=false; handoffWavs.removeAll(); lastControlID=nil; segmenter=TottiDuplexSegmenter()
            selectedUID=nil; TottiConversationAudio.end()
        }
    }
    private func reply(_ type:String,_ id:String,_ message:String) {
        send(["type":type,"request_id":id,"message":message])
    }
    private enum Failure:LocalizedError {
        case message(String)
        var errorDescription:String? { if case let .message(text)=self { return text }; return nil }
    }
}
#endif
