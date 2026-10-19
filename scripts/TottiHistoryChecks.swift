import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@main struct Checks {
    static func main() throws {
        let token = String(repeating: "x", count: 40)
        let config = TottiIntegration(baseURL: "https://example.test", token: token, sessionID: "history-1", mode: "chat")
        for mode in ["chat", "rag", "web"] {
            let c = TottiIntegration(baseURL: "https://example.test/", token: token, sessionID: "history-1", mode: mode)
            let r = try c.chatRequest(text: "さっきの合言葉は？")
            precondition(r.url!.absoluteString == "https://example.test/api/chat")
            precondition(r.value(forHTTPHeaderField: "Authorization") == "Bearer " + token)
            let b = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: String]
            precondition(b["session_id"] == "history-1" && b["mode"] == mode)
        }
        func data(_ fields: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: fields) }
        let fields: [String: Any] = ["session_id": "history-1", "answer": "青い灯台", "history_saved": true, "revision": 2]
        let valid = try data(fields)
        let a = try config.decode(valid, status: 200)
        precondition(a.text == "青い灯台" && a.saved && a.revision == 2)
        for code in [401, 409, 500] {
            do { _ = try config.decode(valid, status: code); fatalError("HTTP error accepted") } catch {}
        }
        for key in ["session_id", "answer", "history_saved", "revision"] {
            var bad = fields; bad.removeValue(forKey: key)
            do { _ = try config.decode(data(bad), status: 200); fatalError("Missing field accepted") } catch {}
        }
        var wrong = fields; wrong["session_id"] = "other"
        do { _ = try config.decode(data(wrong), status: 200); fatalError("Wrong session accepted") } catch {}
        do { _ = try config.decode(Data("bad json".utf8), status: 200); fatalError("Bad JSON accepted") } catch {}
        let rag = TottiIntegration(baseURL: "https://example.test", token: token, sessionID: "history-1", mode: "rag")
        let noHistory = try data(["session_id":"history-1", "answer":"資料なし", "history_saved":false])
        let r = try rag.decode(noHistory, status: 200); precondition(!r.saved)
        do { _ = try config.decode(noHistory, status: 200); fatalError("Unsaved chat accepted") } catch {}
        for url in ["http://example.test", "https://user:pw@example.test", "https://example.test/api/chat", "https://example.test?token=x"] {
            do { _ = try TottiIntegration(baseURL:url, token:token, sessionID:"s", mode:"chat").chatRequest(text:"x"); fatalError("Bad URL accepted") } catch {}
        }
        print("PASS Totti history request/JSON contracts, errors, session matching, saved/unsaved distinction")
    }
}
