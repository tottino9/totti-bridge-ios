import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct TottiIntegration {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(s) = self { return s }; return nil }
    }
    let baseURL: String
    let token: String
    let sessionID: String
    let mode: String
    func chatRequest(text: String) throws -> URLRequest {
        guard let c = URLComponents(string: baseURL), c.scheme == "https", c.host != nil,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/" else { throw Failure.invalid("WorkerのHTTPSルートURLを入力してください。") }
        guard token.count >= 32, token.count <= 256, !token.contains("\n"), !token.contains("\r") else { throw Failure.invalid("メニュー用トークンを設定してください。") }
        guard ["chat", "rag", "web"].contains(mode), Self.validID(sessionID) else { throw Failure.invalid("モードまたは履歴IDが不正です。") }
        var request = URLRequest(url: URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/chat")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.allowsCellularAccess = true
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "session_id": sessionID, "mode": mode])
        return request
    }
    static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
    }
    struct Answer {
        let text: String
        let sessionID: String
        let saved: Bool
        let revision: Int?
        let details: Data
    }
    func decode(_ data: Data, status: Int) throws -> Answer {
        guard (200...299).contains(status) else {
            switch status {
            case 401: throw Failure.invalid("履歴用トークンを確認してください。")
            case 409: throw Failure.invalid("同じ履歴へ同時に送信されました。少し待って話しかけてください。")
            default: throw Failure.invalid("履歴API HTTP \(status)")
            }
        }
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = fields["answer"] as? String,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fields["session_id"] as? String == sessionID,
              let saved = fields["history_saved"] as? Bool else {
            throw Failure.invalid("履歴APIの回答形式または履歴IDが一致しません。")
        }
        let revision = fields["revision"] as? Int
        if saved && (revision ?? 0) < 1 { throw Failure.invalid("履歴の保存結果を確認できません。") }
        if mode == "chat" && !saved { throw Failure.invalid("会話履歴の保存を確認できません。") }
        let details: [String: Any] = ["session_id": sessionID, "history_saved": saved,
            "revision": revision ?? 0, "citations": fields["citations"] ?? [],
            "references": fields["references"] ?? [], "web_search_completed": fields["web_search_completed"] ?? false]
        return Answer(text: answer, sessionID: sessionID, saved: saved, revision: revision,
                      details: try JSONSerialization.data(withJSONObject: details))
    }

}

#if canImport(Security) && !TOTTI_CONTRACT_TEST
@MainActor
enum TottiIntegrationStore {
    static let defaults = UserDefaults.standard
    static let keychain = KeychainSecretStore(service: "com.totti.integration")
    static func current() throws -> TottiIntegration? {
        guard defaults.bool(forKey: "totti.integration.enabled") else { return nil }
        let config = TottiIntegration(baseURL: defaults.string(forKey: "totti.integration.url") ?? "", token: try keychain.string(account: "menu-token") ?? "", sessionID: defaults.string(forKey: "totti.integration.history") ?? "", mode: defaults.string(forKey: "totti.integration.mode") ?? "chat")
        _ = try config.chatRequest(text: "validation")
        return config
    }
    static func save(enabled: Bool, url: String, token: String, history: String, mode: String) throws {
        let id = history.isEmpty ? UUID().uuidString : history
        let actualToken = token.isEmpty ? (try keychain.string(account: "menu-token") ?? "") : token
        if enabled { _ = try TottiIntegration(baseURL: url, token: actualToken, sessionID: id, mode: mode).chatRequest(text: "validation") }
        if !token.isEmpty { try keychain.set(token, account: "menu-token") }
        defaults.set(url, forKey: "totti.integration.url")
        defaults.set(id, forKey: "totti.integration.history")
        defaults.set(mode, forKey: "totti.integration.mode")
        defaults.set(enabled, forKey: "totti.integration.enabled")
    }
    static func accept(_ answer: TottiIntegration.Answer, expected: TottiIntegration) {
        guard defaults.string(forKey: "totti.integration.history") == expected.sessionID,
              defaults.string(forKey: "totti.integration.url") == expected.baseURL else { return }
        defaults.set(answer.details, forKey: "totti.integration.sources")
        defaults.set(answer.saved ? "履歴への保存を確認しました。" : "回答を受信しました。今回は履歴未保存です。", forKey: "totti.integration.lastResult")
    }
}
#endif
