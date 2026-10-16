import AVFoundation
import Foundation
import UIKit

/// Conversation-long voice-processing input. No per-answer audio-session restart.
@MainActor
final class TottiHFPCapture {
    private let send: ([String: Any]) -> Void
    private let relay: TottiVoiceRelay
    private let audio = AVAudioSession.sharedInstance()
    private var tapInstalled = false
    private var engine: AVAudioEngine?
    private var activeID: String?
    private var selectedUID: String?
    private var startup: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var generation = UUID()
    private var ready = false
    private var segmenter = TottiDuplexSegmenter()
    private var startedAt = 0.0
    private var lastFrameAt = 0.0
    private var quietSince = 0.0
    private var observers: [NSObjectProtocol] = []
    init(send: @escaping ([String: Any]) -> Void, relay: TottiVoiceRelay) {
        self.send = send; self.relay = relay
        relay.onSessionClosed = { [weak self] in self?.stopEngine() }
    }
    func handle(_ fields: [String: Any]) -> Bool {
        guard let type = fields["type"] as? String, type.hasPrefix("totti_mic_") else { return false }
        guard let id = fields["request_id"] as? String, !id.isEmpty, id.utf8.count <= 128 else { return true }
        switch type {
        case "totti_mic_start":
            if activeID == id { if ready { announceReady() }; return true }
            guard activeID == nil else { return true }
            guard relay.acceptSession(fields["session_id"] as? String ?? "legacy") else {
                send(["type": "totti_session_end", "request_id": id]); return true
            }
            activeID = id; generation = UUID(); ready = false; segmenter = TottiDuplexSegmenter()
            startedAt = ProcessInfo.processInfo.systemUptime; lastFrameAt = startedAt; quietSince = startedAt
            relay.beginContinuous(id)
            startup = Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.start(id) }
                catch is CancellationError { }
                catch { if self.activeID == id { self.fail(error.localizedDescription) } }
            }
        case "totti_mic_stop":
            if activeID == id { consume(segmenter.finish()) }
        case "totti_mic_cancel":
            if activeID == id { relay.cancelCaptured(id) }
        default: break
        }
        return true
    }
    private func start(_ id: String) async throws {
        let permitted: Bool
        switch audio.recordPermission {
        case .granted: permitted = true
        case .denied: permitted = false
        case .undetermined:
            send(["type": "totti_status", "request_id": id, "message": "iPhoneでマイクの利用を許可してください。"])
            permitted = await withCheckedContinuation { continuation in
                audio.requestRecordPermission { continuation.resume(returning: $0) }
            }
        @unknown default: permitted = false
        }
        try Task.checkCancellation()
        guard activeID == id else { return }
        guard permitted else { throw Failure.message("iPhoneの設定でマイク利用を許可してください。") }
        guard UIApplication.shared.applicationState == .active else {
            throw Failure.message("会話の開始時はiPhoneのトッティを前面に開いてください。")
        }
        let owner = "duplex-start:" + id
        guard TottiAudioGate.acquire(owner) else { throw Failure.message("音声処理が使用中です。") }
        defer { TottiAudioGate.release(owner) }
        if !TottiAudioGate.conversationActive {
            try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try audio.setActive(true)
            TottiAudioGate.retainConversation()
        }
        let routed = audio.currentRoute.inputs.filter { $0.portType == .bluetoothHFP && Self.isGlasses($0.portName) }
        let port: AVAudioSessionPortDescription
        if routed.count == 1 { port = routed[0] }
        else {
            var ports = audio.availableInputs ?? []
            for _ in 0..<60 {
                try Task.checkCancellation()
                if ports.contains(where: { $0.portType == .bluetoothHFP && Self.isGlasses($0.portName) }) { break }
                try await Task.sleep(nanoseconds: 50_000_000); ports = audio.availableInputs ?? []
            }
            let choice = try TottiHFPInputPolicy.choose(ports.map(Self.describe))
            guard let chosen = ports.first(where: { $0.uid == choice.uid }) else { throw Failure.message("眼鏡のマイクが見つかりません。") }
            port = chosen
        }
        selectedUID = port.uid
        if !validRoute() { try audio.setPreferredInput(port) }
        for _ in 0..<60 {
            try Task.checkCancellation()
            if validRoute() { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard activeID == id, validRoute() else { throw Failure.message("眼鏡のマイクへの切替を確認できませんでした。") }
        let capture = AVAudioEngine()
        engine = capture
        // Must be enabled while stopped. AEC support on the actual HFP device
        // remains a hardware test gate; never fall back silently to raw echo.
        try capture.inputNode.setVoiceProcessingEnabled(true)
        let source = capture.inputNode.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let destination = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: destination) else {
            throw Failure.message("眼鏡の音声形式を変換できません。")
        }
        let token = generation
        capture.inputNode.installTap(onBus: 0, bufferSize: 1024, format: source) { [weak self] input, _ in
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / source.sampleRate) + 64)
            guard let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if error != nil || status == .error {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.fail("音声形式の変換に失敗しました。")
                }
                return
            }
            guard output.frameLength > 0, let pointer = output.int16ChannelData?[0] else { return }
            let bytes = Data(bytes: pointer, count: Int(output.frameLength) * 2)
            DispatchQueue.main.async { [weak self] in self?.received(bytes, generation: token) }
        }
        tapInstalled = true
        capture.prepare(); try capture.start()
        guard validRoute() else { throw Failure.message("音声処理開始時に眼鏡のマイクが切れました。") }
        observeInterruptions()
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard let self, self.activeID == id else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard self.validRoute(), self.engine?.isRunning == true else {
                    self.fail("眼鏡の音声接続が切れたため停止しました。"); return
                }
                guard now - self.lastFrameAt < 10 else {
                    self.fail("眼鏡の音声入力が10秒間届かないため停止しました。"); return
                }
                self.send(["type": "totti_heartbeat", "request_id": id])
                if !self.segmenter.speaking, now - self.quietSince >= 30 {
                    self.relay.promptAfterSilence(id)
                }
            }
        }
        startup = nil
    }
    private func received(_ bytes: Data, generation token: UUID) {
        guard token == generation, activeID != nil else { return }
        guard validRoute() else { fail("眼鏡のマイク接続が切れました。"); return }
        lastFrameAt = ProcessInfo.processInfo.systemUptime
        if !ready { ready = true; announceReady() }
        consume(segmenter.append(bytes))
    }
    private func consume(_ events: [TottiDuplexSegmenter.Event]) {
        for event in events {
            switch event {
            case .began: quietSince = ProcessInfo.processInfo.systemUptime; relay.speechBegan()
            case .ended(let wav): quietSince = ProcessInfo.processInfo.systemUptime; relay.submitContinuous(wav)
            }
        }
    }
    private func announceReady() {
        guard let activeID, ready else { return }
        send(["type": "totti_listening", "request_id": activeID, "message": "話しかけてください",
              "prepare_ms": Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000), "duplex": true])
    }
    private func observeInterruptions() {
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in Task { @MainActor [weak self] in self?.fail("iPhoneの音声処理が中断されました。会話を再開してください。") }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor [weak self] in
                guard let self, self.activeID != nil else { return }
                if !self.validRoute() { self.fail("眼鏡の音声接続が変更されたため停止しました。") }
            }
        })
    }
    private func validRoute() -> Bool {
        guard let selectedUID else { return false }
        return TottiHFPInputPolicy.matchesActual(audio.currentRoute.inputs.map(Self.describe), selectedUID: selectedUID)
    }
    private static func isGlasses(_ name: String) -> Bool {
        let name = name.lowercased(); return name.contains("rokid") || name.contains("glasses")
    }
    private static func describe(_ port: AVAudioSessionPortDescription) -> TottiHFPInputPolicy.Input {
        .init(uid: port.uid, name: port.portName, isHFP: port.portType == .bluetoothHFP)
    }
    func controlPaused(reason: String?) {
        if !TottiControlPausePolicy.mayContinueHFP(reason: reason) { connectionLost(reason: reason ?? "unknown") }
    }
    func connectionLost(reason: String = "linkDisconnected") {
        if activeID != nil { fail("眼鏡との制御接続が切れました [\(reason)]") }
        else { relay.connectionLost() }
    }
    private func fail(_ message: String) {
        guard let id = activeID else { return }
        send(["type": "totti_error", "request_id": id, "message": message])
        relay.connectionLost()
    }
    private func stopEngine() {
        generation = UUID(); startup?.cancel(); startup = nil; watchdog?.cancel(); watchdog = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
        if let engine { engine.stop(); if tapInstalled { engine.inputNode.removeTap(onBus: 0) } }
        tapInstalled = false
        engine = nil; activeID = nil; selectedUID = nil; ready = false; segmenter = TottiDuplexSegmenter()
    }
    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}
