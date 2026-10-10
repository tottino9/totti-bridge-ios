import CryptoKit
import Foundation

/// Receives acknowledged WAV chunks and uses the iPhone network for the existing Worker.
@MainActor
final class TottiVoiceRelay {
    private struct Upload {
        let id: String
        let expectedBytes: Int
        let chunks: Int
        let chunkBytes: Int
        let digest: String
        var next = 0
        var data = Data()
        var touched = Date()
    }
    private var upload: Upload?
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

    func handle(_ fields: [String: Any]) -> Bool {
        guard let type = fields["type"] as? String, type.hasPrefix("totti_voice_") else { return false }
        guard let id = fields["request_id"] as? String, !id.isEmpty, id.utf8.count <= 128 else { return true }
        if let old = upload, Date().timeIntervalSince(old.touched) > 45 {
            upload = nil
            reply("totti_error", old.id, "音声転送が途中で止まりました。")
        }
        switch type {
        case "totti_voice_begin":
            if upload?.id == id { ack(id, -1); return true }
            guard activeID == nil, upload == nil else {
                reply("totti_error", id, "前の質問に回答中です。")
                return true
            }
            let chunkBytes = fields["chunk_bytes"] as? Int ?? 2048
            guard [128, 2048].contains(chunkBytes), !finishedIDs.contains(id),
                  let bytes = fields["bytes"] as? Int, (45...1_048_576).contains(bytes),
                  let chunks = fields["chunks"] as? Int, chunks == (bytes + chunkBytes - 1) / chunkBytes,
                  let digest = fields["sha256"] as? String, digest.count == 64 else {
                reply("totti_error", id, "音声転送の情報が不正です。")
                return true
            }
            upload = Upload(id: id, expectedBytes: bytes, chunks: chunks, chunkBytes: chunkBytes, digest: digest)
            ack(id, -1)
            print("[TottiVoice] begin id=\(id) bytes=\(bytes) chunks=\(chunks)")
        case "totti_voice_chunk":
            guard var value = upload, value.id == id,
                  let seq = fields["seq"] as? Int, seq >= 0, seq < value.chunks,
                  let encoded = fields["data"] as? String, encoded.utf8.count <= 2800,
                  let bytes = Data(base64Encoded: encoded), bytes.count <= value.chunkBytes else {
                reply("totti_error", id, "音声転送の断片を読めませんでした。")
                return true
            }
            if seq < value.next { ack(id, seq); return true }
            guard seq == value.next,
                  bytes.count == min(value.chunkBytes, value.expectedBytes - value.data.count) else {
                upload = nil
                reply("totti_error", id, "音声転送の順序が不正です。")
                return true
            }
            value.data.append(bytes)
            value.next += 1
            value.touched = Date()
            upload = value
            ack(id, seq)
        case "totti_voice_end":
            if activeID == id || finishedIDs.contains(id) {
                if let seq = fields["seq"] as? Int { ack(id, seq) }
                return true
            }
            guard let value = upload, value.id == id,
                  value.next == value.chunks, value.data.count == value.expectedBytes,
                  SHA256.hash(data: value.data).map({ String(format: "%02x", $0) }).joined() == value.digest,
                  value.data.prefix(4) == Data("RIFF".utf8),
                  value.data.subdata(in: 8..<12) == Data("WAVE".utf8) else {
                if upload?.id == id { upload = nil }
                reply("totti_error", id, "転送した音声の検証に失敗しました。")
                return true
            }
            upload = nil
            activeID = id
            ack(id, value.chunks)
            reply("totti_status", id, "iPhoneからAIへ送信中…")
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.askWorker(id, wav: value.data)
            }
        case "totti_voice_cancel":
            if upload?.id == id { upload = nil }
            if activeID == id {
                task?.cancel()
                speechTimeout?.cancel()
                speech.cancel(requestID: id)
                finish(id)
            }
        default: break
        }
        return true
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
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = body
            print("[TottiVoice] worker POST id=\(id) bytes=\(wav.count)")
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
    private func ack(_ id: String, _ seq: Int) {
        send(["type": "totti_voice_ack", "request_id": id, "seq": seq])
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
