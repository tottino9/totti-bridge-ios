import Foundation

/// Keep control, user text, answers and errors. Routine diagnostics stay on iPhone.
enum TottiDeliveryPolicy {
    static func isExitPhrase(_ text: String) -> Bool {
        let normalized = text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).joined()
        return ["バイバイ", "ばいばい", "さようなら", "終了", "終わり", "会話を終了", "会話を終了して"].contains(normalized)
    }
    static let silenceSeconds: TimeInterval = 2
    static func shouldSend(_ type: String) -> Bool {
        !["totti_capture_info", "totti_audio_status"].contains(type)
    }
}

/// Stops obsolete completion retries as soon as the next microphone request arrives.
struct TottiCompletionRetryPolicy {
    private(set) var revision = 0
    mutating func invalidate() { revision &+= 1 }
    func isCurrent(_ token: Int) -> Bool { revision == token }
}

/// One prompt per quiet interval; valid recognized speech arms the next interval.
struct TottiConversationPolicy {
    private(set) var hasAskedToEnd = false
    mutating func takeSilencePrompt() -> String? {
        guard !hasAskedToEnd else { return nil }
        hasAskedToEnd = true
        return "会話を終了しますか？ 終了する場合はバイバイと言ってください。"
    }
    mutating func recognizedSpeech() { hasAskedToEnd = false }
    static func isNoSpeechResponse(user: String, answer: String) -> Bool {
        let trim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            answer.trimmingCharacters(in: trim) == "音声を認識できませんでした"
    }
}
