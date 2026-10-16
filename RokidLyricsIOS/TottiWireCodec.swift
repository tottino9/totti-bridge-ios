import Foundation

/// Negotiated v2 control packets. Text is never truncated; legacy peers retain
/// the original schema. No packet is split into typing-animation messages.
enum TottiWireCodec {
    static let codes: [String: Int] = [
        "totti_heartbeat": 0, "totti_listening": 1, "totti_thinking": 2,
        "totti_answer": 3, "totti_turn_error": 4, "totti_error": 5,
        "totti_session_end": 6, "totti_status": 7, "totti_speech_started": 8,
        "totti_mic_ack": 9, "totti_audio_error": 10
    ]
    static func encode(_ event: [String: Any], negotiatedVersion: Int) -> [String: Any] {
        guard negotiatedVersion == 2, let type = event["type"] as? String,
              let code = codes[type], let request = event["request_id"] as? String else { return event }
        var packet: [String: Any] = ["v": 2, "r": request, "k": code]
        if let turn = event["turn_id"] as? String, !turn.isEmpty { packet["i"] = turn }
        let text = event[type == "totti_thinking" ? "text" : "message"] as? String ?? ""
        // Ready and ACK labels are local constants; do not transport them repeatedly.
        if !text.isEmpty && code != 1 && code != 9 { packet["x"] = text }
        if let sent = event["sent_wall_ms"] { packet["m"] = sent }
        if let prepared = event["prepare_ms"] { packet["p"] = prepared }
        return packet
    }
    static func decode(_ packet: [String: Any]) -> [String: Any]? {
        guard (packet["v"] as? Int) == 2 else { return packet }
        guard let code = packet["k"] as? Int, let type = codes.first(where: { $0.value == code })?.key,
              let request = packet["r"] as? String, !request.isEmpty else { return nil }
        var event: [String: Any] = ["type": type, "request_id": request, "message": ""]
        if let turn = packet["i"] as? String { event["turn_id"] = turn }
        if code == 2 { event["text"] = packet["x"] as? String ?? "" }
        else { event["message"] = packet["x"] as? String ?? "" }
        if code == 1 { event["message"] = "話しかけてください" }
        if code == 9 { event["message"] = "start" }
        if let sent = packet["m"] { event["sent_wall_ms"] = sent }
        if let prepared = packet["p"] { event["prepare_ms"] = prepared }
        return event
    }
}
