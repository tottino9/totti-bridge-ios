import Foundation

/// The glasses send only start/stop/cancel commands. Audio comes from the SDK.
@MainActor
final class TottiCxrAudioCapture {
    private struct Recording {
        let id: String
        let began: TimeInterval
        var firstDataAt: TimeInterval?
        var lastDataAt: TimeInterval?
        var buffer = TottiPCMBuffer()
        var formatConfirmed = false
        var stopRequested = false
        var packets = 0
        var pendingFormatData = Data()
        var pendingFormatAt: TimeInterval?
        var lastAckAt: TimeInterval = -Double.infinity
    }
    private var recording: Recording?
    private var watchdog: Task<Void, Never>?
    private var drain: Task<Void, Never>?
    private var recentIDs: [String] = []
    private let send: ([String: Any]) -> Void
    private let startStream: () -> String?
    private let stopStream: () -> String?
    private let relay: TottiVoiceRelay

    init(send: @escaping ([String: Any]) -> Void,
         start: @escaping () -> String?, stop: @escaping () -> String?, relay: TottiVoiceRelay) {
        self.send = send; self.startStream = start; self.stopStream = stop; self.relay = relay
    }

    func handle(_ fields: [String: Any]) -> Bool {
        guard let type = fields["type"] as? String, type.hasPrefix("totti_mic_") else { return false }
        guard let id = fields["request_id"] as? String, !id.isEmpty, id.utf8.count <= 128 else { return true }
        switch type {
        case "totti_mic_start":
            if recording?.id == id { acknowledgeStart(id); return true }
            // Legacy and session notify publishers can deliver the same command twice.
            if recentIDs.contains(id) { return true }
            guard recording == nil, !relay.isBusy else {
                reply("totti_error", id, "前の音声を処理中です。"); return true
            }
            recording = Recording(id: id, began: ProcessInfo.processInfo.systemUptime)
            print("[TottiCapture] START id=\(id) PCM16 sampleRate=\(TottiPCMBuffer.sampleRate) (hardware format pending)")
            if let error = startStream() { fail("公式音声取得の開始失敗: \(error)"); return true }
            acknowledgeStart(id)
            reply("totti_status", id, "眼鏡の音声接続を準備中…")
            watchdog = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    self?.tick()
                    if self?.recording == nil { return }
                }
            }
        case "totti_mic_stop":
            if recording?.id == id { finishCapture() }
        case "totti_mic_cancel":
            if recording?.id == id { abandon() }
            relay.cancelCaptured(id)
        default: break
        }
        return true
    }

    private func acknowledgeStart(_ id: String) {
        guard var value = recording, value.id == id else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - value.lastAckAt >= 10 else { return }
        value.lastAckAt = now
        recording = value
        reply("totti_mic_ack", id, "start")
    }

    func started(codec: Int32, expectedPCM: Int32, channels: UInt32, type: String) {
        guard recording != nil else { return }
        print("[TottiCapture] FORMAT codec=\(codec) channels=\(channels) type=\(type)")
        guard codec == expectedPCM, (1...2).contains(channels) else {
            fail("公式音声の形式が未対応です（codec=\(codec), channels=\(channels)）。"); return
        }
        guard recording?.buffer.data.isEmpty == true else { return }
        recording?.buffer.channels = Int(channels)
        recording?.formatConfirmed = true
        let pending = recording?.pendingFormatData ?? Data()
        recording?.pendingFormatData = Data()
        recording?.pendingFormatAt = nil
        if !pending.isEmpty { receive(pending) }
        if let id = recording?.id {
            reply("totti_capture_info", id, "FORMAT codec=\(codec) channels=\(channels) configuredRate=\(TottiPCMBuffer.sampleRate)")
        }
    }

    func receive(_ data: Data) {
        guard var value = recording, !data.isEmpty else { return }
        guard value.formatConfirmed else {
            guard value.pendingFormatData.count + data.count <= 128_000 else {
                fail("音声形式の通知待ちデータが128KBを超えました。"); return
            }
            if value.pendingFormatAt == nil {
                value.pendingFormatAt = ProcessInfo.processInfo.systemUptime
                print("[TottiCapture] DATA_BEFORE_FORMAT id=\(value.id) bytes=\(data.count)")
                reply("totti_capture_info", value.id, "DATA_BEFORE_FORMAT bytes=\(data.count)")
            }
            value.pendingFormatData.append(data)
            recording = value
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if value.firstDataAt == nil {
            value.firstDataAt = now
            reply("totti_listening", value.id, "聞いています")
            print("[TottiCapture] FIRST_PCM id=\(value.id) bytes=\(data.count)")
        }
        guard value.buffer.data.count + data.count <= 2_000_000 else {
            fail("音声データが上限を超えました。"); return
        }
        value.lastDataAt = now
        value.buffer.append(data, at: now)
        value.packets += 1
        if value.packets == 1 || value.packets % 50 == 0 {
            print("[TottiCapture] PCM id=\(value.id) packets=\(value.packets) bytes=\(value.buffer.data.count) peak=\(value.buffer.peak)")
        }
        recording = value
    }

    private func tick() {
        guard let value = recording, !value.stopRequested else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !value.formatConfirmed, let began = value.pendingFormatAt, now - began > 2 {
            fail("音声データは届きましたが、公式SDKの形式通知が2秒以内に届きませんでした（bytes=\(value.pendingFormatData.count)）。"); return
        }
        if value.firstDataAt == nil, now - value.began > 10 {
            fail("公式SDKから眼鏡の音声が10秒以内に届きませんでした。"); return
        }
        if let last = value.lastDataAt, now - last > 3 {
            fail("眼鏡からの音声ストリームが途中で止まりました。"); return
        }
        if value.buffer.hasSpeech, now - value.buffer.lastSpeechAt >= 3 { finishCapture(); return }
        if now - value.began >= 30 {
            if value.buffer.hasSpeech { finishCapture() }
            else { fail("30秒間、声を検出できませんでした。タップで再開できます。") }
        }
    }

    private func finishCapture() {
        guard var value = recording, !value.stopRequested else { return }
        value.stopRequested = true; recording = value
        watchdog?.cancel(); watchdog = nil
        if let error = stopStream() { fail("公式音声取得の停止失敗: \(error)"); return }
        reply("totti_processing", value.id, "iPhoneからAIへ送信中…")
        // The SDK has no public finish event. Allow trailing PCM to arrive after stop.
        drain = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard let self, let complete = self.recording, complete.id == value.id else { return }
            self.recording = nil; self.drain = nil; self.remember(complete.id)
            guard complete.buffer.data.count >= TottiPCMBuffer.sampleRate * complete.buffer.channels * 2 / 5 else {
                self.reply("totti_error", complete.id, "受信した音声が短すぎます。"); return
            }
            let wav = complete.buffer.wav()
            print("[TottiCapture] WAV_READY id=\(complete.id) bytes=\(wav.count) channels=\(complete.buffer.channels)")
            self.reply("totti_capture_info", complete.id, "WAV_READY bytes=\(wav.count) channels=\(complete.buffer.channels)")
            self.relay.submitCaptured(complete.id, wav: wav)
        }
    }

    func connectionLost() {
        if recording != nil { fail("眼鏡との音声接続が切れました。") }
        relay.connectionLost()
    }

    private func fail(_ message: String) {
        guard let id = recording?.id else { return }
        print("[TottiCapture] ERROR id=\(id) \(message)")
        abandon(); reply("totti_error", id, message)
    }
    private func abandon() {
        watchdog?.cancel(); watchdog = nil; drain?.cancel(); drain = nil
        if let id = recording?.id { remember(id) }
        recording = nil
        _ = stopStream()
    }
    private func remember(_ id: String) {
        recentIDs.append(id); if recentIDs.count > 32 { recentIDs.removeFirst() }
    }
    private func reply(_ type: String, _ id: String, _ message: String) {
        send(["type": type, "request_id": id, "message": message])
    }
}
