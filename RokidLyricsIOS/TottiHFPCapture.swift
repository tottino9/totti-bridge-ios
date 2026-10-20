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
    private var segmenter = TottiDuplexSegmenter()
    private var bargeWindow = false
    private var handoffWav: Data?
    private var began = 0.0
    private var lastPCM = 0.0
    private var generation = UUID()
    var hasLiveConversation:Bool { activeID != nil || relay.isBusy || TottiAudioGate.conversationActive }
    var diagnosticSnapshot:String {
        let age=lastPCM>0 ? Int((ProcessInfo.processInfo.systemUptime-lastPCM)*1000) : -1
        return "stage=\(startupStage) engine=\(duplex.isRunning) hfp=\(validRoute()) pcmAgeMs=\(age) ready=\(readyAcknowledged) capture=\(activeID != nil)"
    }

    init(send: @escaping ([String: Any]) -> Void, relay: TottiVoiceRelay) {
        self.send = send; self.relay = relay
        relay.onSpeechPlaybackChanged = { [weak self] playing in
            guard let self else { return }
            self.bargeWindow = playing
            if playing {
                self.segmenter = TottiDuplexSegmenter()
                if let id = self.relay.speakingRequestID {
                    self.send(["type":"totti_listening", "request_id":id,
                        "message":"話しかけてください", "barge_in":true])
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
            else { relay.interruptSpeech() }
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
        duplex.receive = { [weak self] data in
            guard let self, self.generation == token else { return }
            self.received(data)
        }
        duplex.failed = { [weak self] message in self?.connectionLost(reason:message) }
        try duplex.start()
        startupStage = "engineStarted"
        guard validRoute() else { throw Failure.message("録音開始時に入力が眼鏡以外へ変わりました。") }
        lastPCM = ProcessInfo.processInfo.systemUptime
        startup = nil
        if monitor == nil {
            monitor = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                    guard let self, self.generation == token else { return }
                    if self.relay.sessionEnded { self.cleanup(keepAudio:false); return }
                    guard self.validRoute(), self.duplex.isRunning else {
                        self.connectionLost(reason:"HFP_ROUTE_OR_ENGINE_LOST"); return
                    }
                    let now = ProcessInfo.processInfo.systemUptime
                    guard now-self.lastPCM < 5 else { self.connectionLost(reason:"HFP_PCM_TIMEOUT"); return }
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
    private func received(_ data: Data) {
        if relay.sessionEnded { cleanup(keepAudio:false); return }
        guard validRoute(), duplex.isRunning else { connectionLost(reason:"HFP_ROUTE_CHANGED"); return }
        lastPCM = ProcessInfo.processInfo.systemUptime
        if let id = activeID {
            if readiness.accept(pcmBytes:data.count) {
                startupStage = "receivingPCM"
                readyAcknowledged = true
                acknowledge(id)
                if let wav = handoffWav {
                    handoffWav = nil; submit(id,wav:wav); return
                }
            }
        }
        guard activeID != nil || bargeWindow || segmenter.speaking else {
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
                else { handoffWav = wav }
            }
        }
    }
    private func acknowledge(_ id:String) {
        let now=ProcessInfo.processInfo.systemUptime
        guard now-lastAckAt >= 10 else { return }
        lastAckAt=now
        send(["type":"totti_listening", "request_id":id, "message":"話しかけてください"])
    }
    private func submit(_ id:String,wav:Data) {
        guard activeID == id else { return }
        cleanup(keepAudio:true)
        startupStage = "processingOrPlayback"
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
        if let id=activeID { reply("totti_error",id,"音声処理を停止しました [\(reason)] \(diagnosticSnapshot)") }
        cleanup(keepAudio:false)
        relay.connectionLost()
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
            bargeWindow=false; handoffWav=nil; segmenter=TottiDuplexSegmenter()
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
