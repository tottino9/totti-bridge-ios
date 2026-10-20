import Foundation

/// Uploads PCM captured through official CXR audio APIs using the iPhone network.
@MainActor
final class TottiVoiceRelay {
    private var activeID: String?
    private var task: Task<Void, Never>?
    private var speechTimeout: Task<Void, Never>?
    private var finishedIDs: [String] = []
    private var completionRetries = TottiCompletionRetryPolicy()
    private let send: ([String: Any]) -> Void
    private let speech: TottiSpeechPlayer
    var onSpeechPlaybackChanged: ((Bool) -> Void)?
    var speakingRequestID: String? { speech.speakingRequestID }
    func interruptSpeech() {
        guard let id=activeID, speech.isSpeaking else { return }
        speech.cancel(requestID:id)
        finish(id)
    }
    var capturePhoto: (() async throws -> Data)?

    init(send: @escaping ([String: Any]) -> Void, speech: TottiSpeechPlayer) {
        self.send = send
        self.speech = speech
        speech.onPlaybackChanged = { [weak self] value in self?.onSpeechPlaybackChanged?(value) }
    }

    var isBusy: Bool { activeID != nil }
    private var session = TottiSessionPolicy()
    var sessionEnded: Bool { session.ended }
    func acceptSession(_ id: String) -> Bool { session.accept(id) }
    private var lastCompletionAt: TimeInterval?
    var millisecondsSinceCompletion: Int {
        guard let lastCompletionAt else { return -1 }
        return Int((ProcessInfo.processInfo.systemUptime - lastCompletionAt) * 1000)
    }
    private var conversation = TottiConversationPolicy()
    var hasAskedToEnd: Bool { conversation.hasAskedToEnd }

    func promptAfterSilence(_ id: String) {
        guard !isBusy else { return }
        activeID = id
        guard let message = conversation.takeSilencePrompt() else { finish(id); return }
        reply("totti_answer", id, message)
        speechTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            guard let self, self.activeID == id else { return }
            self.speech.cancel(requestID: id)
            self.finish(id)
        }
        speech.speak(message, requestID: id, completed: { [weak self] in
            self?.finish(id)
        }) { [weak self] type, message in self?.reply(type, id, message) }
    }

    func noteCaptureRequest() { completionRetries.invalidate() }

    func submitCaptured(_ id: String, wav: Data) {
        guard !isBusy, !finishedIDs.contains(id), wav.count > 44 else {
            reply("totti_error", id, "音声処理を開始できませんでした。")
            return
        }
        activeID = id
        // TottiHFPCapture already sent the processing status for this turn.
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.askWorker(id, wav: wav)
        }
    }

    func cancelCaptured(_ id: String) {
        guard activeID == id else { return }
        task?.cancel()
        speechTimeout?.cancel()
        speech.cancel(requestID: id)
        finish(id)
        TottiConversationAudio.end()
    }

    func connectionLost() {
        if let id = activeID {
            reply("totti_error", id, "眼鏡との接続が切れたため音声処理を停止しました。")
            cancelCaptured(id)
        }
        TottiConversationAudio.end()
    }

    private func askWorker(_ id: String, wav: Data) async {
        do {
            let integration = try TottiIntegrationStore.current()
            let boundary = "Totti-" + UUID().uuidString
            var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
            body.append(wav)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var request = URLRequest(url: URL(string: "https://totti-ai.toshiakino-9.workers.dev/glasses/chat")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.allowsCellularAccess = true
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = body
            request.setValue("transcribe", forHTTPHeaderField: "X-Totti-Phase")
            print("[TottiVoice] worker POST id=\(id) bytes=\(wav.count)")
            reply("totti_capture_info", id, "WORKER_POST bytes=\(wav.count)")
            let httpStarted = ProcessInfo.processInfo.systemUptime
            let metrics = TottiNetworkMetrics()
            let (data, response) = try await URLSession.shared.data(for: request, delegate: metrics)
            try Task.checkCancellation()
            guard activeID == id else { return }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw RelayError.message("AIサーバー HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw RelayError.message("AIの回答を読めませんでした。")
            }
            let result: Result
            var alreadyDisplayedUser = false
            if http.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true {
                guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let user = fields["text"] as? String, !user.isEmpty else {
                    throw RelayError.message("音声認識の結果を取得できませんでした。")
                }
                print("[TottiTiming] transcript id=\(id) ms=\(Int((ProcessInfo.processInfo.systemUptime-httpStarted)*1000))")
                if Self.isExitPhrase(user) {
                    finish(id, endingSession: true)
                    return
                }
                conversation.recognizedSpeech()
                send(["type": "totti_thinking", "request_id": id, "message": "考えています…", "text": user])
                alreadyDisplayedUser = true
                var chat = URLRequest(url: request.url!)
                chat.httpMethod = "POST"
                chat.timeoutInterval = 60
                chat.allowsCellularAccess = true
                chat.setValue("application/json", forHTTPHeaderField: "Content-Type")
                chat.httpBody = try JSONSerialization.data(withJSONObject: ["text": user])
                if TottiVisionPolicy.requestsCapture(user) {
                    guard let integration else { throw RelayError.message("写真解析には履歴・記憶連携の設定が必要です。") }
                    guard let capturePhoto else { throw RelayError.message("眼鏡の撮影機能が準備されていません。") }
                    reply("totti_status", id, "写真を撮影しています…")
                    let jpeg = try await capturePhoto()
                    try Task.checkCancellation()
                    guard activeID == id else { return }
                    reply("totti_status", id, "写真を確認しています…")
                    print("[TottiVision] captured id=\(id) jpegBytes=\(jpeg.count)")
                    chat = try integration.visionRequest(text: user, jpeg: jpeg)
                } else if let integration { chat = try integration.chatRequest(text: user) }
                let (answerData, answerResponse) = try await URLSession.shared.data(for: chat)
                try Task.checkCancellation()
                guard activeID == id else { return }
                guard let answerHTTP = answerResponse as? HTTPURLResponse else {
                    throw RelayError.message("AI回答のHTTP情報を取得できませんでした。")
                }
                if let integration {
                    let answer = try integration.decode(answerData, status: answerHTTP.statusCode)
                    TottiIntegrationStore.accept(answer, expected: integration)
                    result = Result(user: user, answer: answer.text)
                    print("[TottiHistory] saved=\(answer.saved) revision=\(answer.revision ?? 0)")
                } else {
                    guard (200...299).contains(answerHTTP.statusCode),
                          let answerBody = String(data: answerData, encoding: .utf8) else {
                        throw RelayError.message("AI回答の取得に失敗しました。")
                    }
                    result = try Self.parseResponse(answerBody)
                }
            } else {
                if integration != nil { throw RelayError.message("音声認識分離APIの応答を確認できませんでした。") }
                // Compatibility with the old Worker during a staged update.
                result = try Self.parseResponse(text)
            }
            if TottiConversationPolicy.isNoSpeechResponse(user: result.user, answer: result.answer) {
                // Legacy Worker represents empty transcription as an answer event.
                // Never speak that answer repeatedly as though it were a conversation.
                activeID = nil
                promptAfterSilence(id)
                return
            }
            if !result.user.isEmpty { conversation.recognizedSpeech() }
            if !alreadyDisplayedUser { reply("totti_user", id, result.user) }
            if Self.isExitPhrase(result.user) {
                finish(id, endingSession: true)
                return
            }
            send(["type": "totti_answer", "request_id": id, "message": result.answer,
                  "network_transport": metrics.transport,
                  "http_ms": Int((ProcessInfo.processInfo.systemUptime - httpStarted) * 1000),
                  "wav_bytes": wav.count])
            speechTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
                guard let self, self.activeID == id else { return }
                self.reply("totti_audio_error", id, "読み上げの完了を確認できませんでした。")
                self.speech.cancel(requestID: id)
                self.finish(id)
            }
            speech.speak(result.answer, requestID: id, completed: { [weak self] in
                self?.finish(id)
            }) { [weak self] type, message in
                self?.reply(type, id, message)
            }
        } catch is CancellationError {
            if activeID == id { finish(id) }
        } catch {
            guard activeID == id else { return }
            print("[TottiVoice] worker error id=\(id) \(error.localizedDescription)")
            reply("totti_error", id, error.localizedDescription)
            finish(id)
        }
    }

    struct Result { let user: String; let answer: String }
    enum RelayError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
    }
    static func parseResponse(_ body: String) throws -> Result {
        var user = "", answer = "", delta = ""
        var done = false
        for line in body.components(separatedBy: .newlines) {
            guard line.hasPrefix("data:"),
                  let bytes = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { continue }
            let text = event["text"] as? String ?? ""
            switch event["type"] as? String {
            case "user": user = text
            case "answer_delta": delta += text
            case "answer": answer = text
            case "error": throw RelayError.message(text.isEmpty ? "AI処理でエラーが発生しました。" : text)
            case "done": done = true
            default: break
            }
        }
        if answer.isEmpty { answer = delta }
        guard done, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RelayError.message("AI回答を最後まで取得できませんでした。")
        }
        return Result(user: user, answer: answer)
    }
    private static func isExitPhrase(_ text: String) -> Bool {
        TottiDeliveryPolicy.isExitPhrase(text)
    }
    private func reply(_ type: String, _ id: String, _ message: String) {
        send(["type": type, "request_id": id, "message": message])
    }
    private func finish(_ id: String, endingSession: Bool = false) {
        guard activeID == id else { return }
        if endingSession { session.end() }
        speechTimeout?.cancel()
        speechTimeout = nil
        activeID = nil
        task = nil
        finishedIDs.append(id)
        if finishedIDs.count > 32 { finishedIDs.removeFirst() }
        lastCompletionAt = ProcessInfo.processInfo.systemUptime
        let eventType = endingSession ? "totti_session_end" : "totti_turn_done"
        print("[TottiTiming] completion id=\(id) type=\(eventType) uptime=\(ProcessInfo.processInfo.systemUptime)")
        send(["type": eventType, "request_id": id])
        if endingSession { TottiConversationAudio.end() }
        // Retain retries for a lost completion, but stop when the next capture arrives.
        completionRetries.invalidate()
        let retryToken = completionRetries.revision
        Task { @MainActor [weak self] in
            for _ in 0..<2 {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.completionRetries.isCurrent(retryToken) else { return }
                self.send(["type": eventType, "request_id": id])
            }
        }
    }
}
