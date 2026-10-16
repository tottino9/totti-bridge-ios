import Foundation

/// One control session, independently identified HTTP turns. New speech never
/// cancels an older answer. Only explicit session termination cancels requests.
@MainActor
final class TottiVoiceRelay {
    private let send: ([String: Any]) -> Void
    private let speech: TottiSpeechPlayer
    private let performRequest: (URLRequest) async throws -> (Data, URLResponse)
    private var session = TottiSessionPolicy()
    private var conversation = TottiConversationPolicy()
    private var controlID: String?
    private(set) var lastHUDSendAt = ProcessInfo.processInfo.systemUptime
    private var tasks: [String: Task<Void, Never>] = [:]
    private var turns = TottiDuplexTurns()
    private var spokenID: String?
    private var speechTimeout: Task<Void, Never>?
    private var speechQueue: [(String, String)] = []
    private var userSpeaking = false
    private var captureTurn: String?
    private var awaitingTranscript = Set<String>()
    var onSessionClosed: (() -> Void)?
    var isBusy: Bool { !tasks.isEmpty || spokenID != nil }
    var sessionEnded: Bool { session.ended }
    var hasAskedToEnd: Bool { conversation.hasAskedToEnd }
    var millisecondsSinceCompletion: Int { 0 }
    init(send: @escaping ([String: Any]) -> Void, speech: TottiSpeechPlayer,
         performRequest: @escaping (URLRequest) async throws -> (Data, URLResponse) = {
             try await URLSession.shared.data(for: $0)
         }) {
        self.send = send; self.speech = speech; self.performRequest = performRequest
    }
    func acceptSession(_ id: String) -> Bool { session.accept(id) }
    func beginContinuous(_ id: String) {
        print("[TottiBuild] optimized-20261016.1")
        lastHUDSendAt = ProcessInfo.processInfo.systemUptime
        controlID = id; turns = TottiDuplexTurns(); conversation = TottiConversationPolicy()
        userSpeaking = false; captureTurn = nil; awaitingTranscript.removeAll()
    }
    func noteCaptureRequest() { }
    func speechBegan() {
        guard controlID != nil, !sessionEnded else { return }
        userSpeaking = true
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased(); captureTurn = id
        if let playing = spokenID {
            speech.cancel(requestID: playing)
            speechTimeout?.cancel(); speechTimeout = nil; spokenID = nil
        }
        // HUD stays ready; speech onset is local, not another CXR packet.
    }
    func submitContinuous(_ wav: Data) {
        guard let id = captureTurn, controlID != nil, !sessionEnded else { return }
        captureTurn = nil; userSpeaking = false
        print("[TottiPerf] stage=utterance_end turn=\(id) at=\(ProcessInfo.processInfo.systemUptime) bytes=\(wav.count)")
        awaitingTranscript.insert(id)
        submitCaptured(id, wav: wav)
        // Microphone never stopped; no repeated readiness notification.
    }
    func submitCaptured(_ id: String, wav: Data) {
        guard wav.count > 44, turns.insert(id) else { return }
        tasks[id] = Task { @MainActor [weak self] in await self?.askWorker(id, wav: wav) }
    }
    func promptAfterSilence(_ id: String) {
        guard !isBusy, !userSpeaking, let message = conversation.takeSilencePrompt() else { return }
        let promptID = UUID().uuidString
        emit("totti_answer", turn: promptID, message: message)
        speechQueue.append((promptID, message)); drainSpeech()
    }
    func cancelCaptured(_ id: String) {
        // A control cancellation ends this conversation, not one ordinary answer.
        guard id == controlID || turns.contains(id) else { return }
        close(emitTerminal: false)
    }
    func connectionLost() { close(emitTerminal: false) }
    private func close(emitTerminal: Bool) {
        guard let control = controlID else { return }
        session.end(); controlID = nil; turns.close()
        for task in tasks.values { task.cancel() }; tasks.removeAll()
        if let id = spokenID { speech.cancel(requestID: id) }
        speechTimeout?.cancel(); speechTimeout = nil; spokenID = nil
        speechQueue.removeAll(); awaitingTranscript.removeAll(); userSpeaking = false; captureTurn = nil
        onSessionClosed?()
        TottiConversationAudio.end()
        if emitTerminal {
            send(["type": "totti_session_end", "request_id": control])
            Task { @MainActor [weak self] in
                for _ in 0..<2 {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard let self, self.controlID == nil else { return }
                    self.send(["type": "totti_session_end", "request_id": control])
                }
            }
        }
    }
    private func emit(_ type: String, turn: String? = nil, message: String = "", text: String? = nil) {
        guard let controlID else { return }
        var event: [String: Any] = ["type": type, "request_id": controlID, "message": message]
        if let turn { event["turn_id"] = turn }
        if let text { event["text"] = text }
        if TottiDeliveryPolicy.shouldSend(type) {
            lastHUDSendAt = ProcessInfo.processInfo.systemUptime
        }
        send(event)
    }
    private func drainSpeech() {
        guard controlID != nil, !userSpeaking, awaitingTranscript.isEmpty,
              spokenID == nil, !speechQueue.isEmpty else { return }
        let (id, answer) = speechQueue.removeFirst(); spokenID = id
        speechTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
            guard let self, self.spokenID == id else { return }
            self.speech.cancel(requestID: id); self.speechFinished(id)
        }
        speech.speak(answer, requestID: id, completed: { [weak self] in self?.speechFinished(id) }) {
            [weak self] type, message in self?.emit(type, turn: id, message: message)
        }
    }
    private func speechFinished(_ id: String) {
        guard spokenID == id else { return }
        speechTimeout?.cancel(); speechTimeout = nil; spokenID = nil
        drainSpeech()
    }
    private func askWorker(_ id: String, wav: Data) async {
        defer {
            tasks[id] = nil; awaitingTranscript.remove(id)
            _ = turns.complete(id); drainSpeech()
        }
        do {
            let boundary = "Totti-" + UUID().uuidString
            var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
            body.append(wav); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var request = URLRequest(url: URL(string: "https://totti-ai.toshiakino-9.workers.dev/glasses/chat")!)
            request.httpMethod = "POST"; request.timeoutInterval = 60; request.allowsCellularAccess = true
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("transcribe", forHTTPHeaderField: "X-Totti-Phase"); request.httpBody = body
            let (data, response) = try await performRequest(request)
            try Task.checkCancellation()
            guard turns.contains(id) else { return }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw RelayError.message("音声認識サーバー HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            print("[TottiPerf] stage=transcript_received turn=\(id) at=\(ProcessInfo.processInfo.systemUptime)")
            let decoded = try Self.decodeTranscription(data, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "")
            let user = decoded.user
            if user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emit("totti_turn_error", turn: id, message: "聞き取れませんでした。もう一度話してください。")
                return
            }
            if TottiDeliveryPolicy.isExitPhrase(user) { close(emitTerminal: true); return }
            conversation.recognizedSpeech()
            emit("totti_thinking", turn: id, message: "", text: user)
            awaitingTranscript.remove(id)
            drainSpeech()
            let result: Result
            if let completed = decoded.completed {
                result = completed
            } else {
            var chat = URLRequest(url: request.url!)
            chat.httpMethod = "POST"; chat.timeoutInterval = 60; chat.allowsCellularAccess = true
            chat.setValue("application/json", forHTTPHeaderField: "Content-Type")
            chat.httpBody = try JSONSerialization.data(withJSONObject: ["text": user])
            let (answerData, answerResponse) = try await performRequest(chat)
            try Task.checkCancellation()
            guard turns.contains(id) else { return }
            guard let answerHTTP = answerResponse as? HTTPURLResponse, (200...299).contains(answerHTTP.statusCode),
                  let answerBody = String(data: answerData, encoding: .utf8) else {
                throw RelayError.message("AI回答の取得に失敗しました。")
            }
                result = try Self.parseResponse(answerBody)
            }
            print("[TottiPerf] stage=answer_received turn=\(id) at=\(ProcessInfo.processInfo.systemUptime)")
            emit("totti_answer", turn: id, message: result.answer)
            speechQueue.append((id, result.answer)); drainSpeech()
        } catch is CancellationError { }
        catch {
            guard turns.contains(id) else { return }
            emit("totti_turn_error", turn: id, message: error.localizedDescription)
        }
    }
    struct TranscriptionReply { let user: String; let completed: Result? }
    static func decodeTranscription(_ data: Data, contentType: String) throws -> TranscriptionReply {
        if contentType.lowercased().contains("application/json") {
            guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let text = fields["text"] as? String else {
                throw RelayError.message("音声認識サーバーの応答形式を確認できませんでした。")
            }
            return .init(user: text.trimmingCharacters(in: .whitespacesAndNewlines), completed: nil)
        }
        guard let body = String(data: data, encoding: .utf8), body.contains("data:") else {
            throw RelayError.message("音声認識サーバーから想定外の応答が届きました。")
        }
        // Worker failures use SSE even when transcribe was requested. Do not
        // feed them to a JSON parser or send the failure message to speech.
        let result = try parseResponse(body)
        if TottiConversationPolicy.isNoSpeechResponse(user: result.user, answer: result.answer) {
            return .init(user: "", completed: nil)
        }
        guard !result.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RelayError.message(result.answer)
        }
        return .init(user: result.user, completed: result)
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

}
