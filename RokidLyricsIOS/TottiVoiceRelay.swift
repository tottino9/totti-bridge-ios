import Foundation

/// Uploads PCM captured through official CXR audio APIs using the iPhone network.
@MainActor
final class TottiVoiceRelay {
    private var activeID: String?
    private var task: Task<Void, Never>?
    private var speechTimeout: Task<Void, Never>?
    private var finishedIDs: [String] = []
    private let send: ([String: Any]) -> Void
    private let speech: TottiSpeechPlayer

    init(send: @escaping ([String: Any]) -> Void, speech: TottiSpeechPlayer) {
        self.send = send
        self.speech = speech
    }

    var isBusy: Bool { activeID != nil }

    func submitCaptured(_ id: String, wav: Data) {
        guard !isBusy, !finishedIDs.contains(id), wav.count > 44 else {
            reply("totti_error", id, "音声処理を開始できませんでした。")
            return
        }
        activeID = id
        reply("totti_status", id, "iPhoneからAIへ送信中…")
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
    }

    func connectionLost() {
        if let id = activeID {
            reply("totti_error", id, "眼鏡との接続が切れたため音声処理を停止しました。")
            cancelCaptured(id)
        }
    }

    private func askWorker(_ id: String, wav: Data) async {
        do {
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
            print("[TottiVoice] worker POST id=\(id) bytes=\(wav.count)")
            reply("totti_capture_info", id, "WORKER_POST bytes=\(wav.count)")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard activeID == id else { return }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw RelayError.message("AIサーバー HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw RelayError.message("AIの回答を読めませんでした。")
            }
            let result = try Self.parseResponse(text)
            if !result.user.isEmpty { reply("totti_user", id, result.user) }
            if Self.isExitPhrase(result.user) {
                reply("totti_session_end", id, "会話を終了します。")
                finish(id)
                return
            }
            reply("totti_answer", id, result.answer)
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
        ["バイバイ", "ばいばい", "さようなら", "終了", "終わり"].contains { text.contains($0) }
    }
    private func reply(_ type: String, _ id: String, _ message: String) {
        send(["type": type, "request_id": id, "message": message])
    }
    private func finish(_ id: String) {
        guard activeID == id else { return }
        speechTimeout?.cancel()
        speechTimeout = nil
        activeID = nil
        task = nil
        finishedIDs.append(id)
        if finishedIDs.count > 32 { finishedIDs.removeFirst() }
        send(["type": "totti_turn_done", "request_id": id])
        // A delayed SDK copy is harmless: the glasses match every message to its turn UUID.
        Task { @MainActor [weak self] in
            for _ in 0..<2 {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                self?.send(["type": "totti_turn_done", "request_id": id])
            }
        }
    }
}
