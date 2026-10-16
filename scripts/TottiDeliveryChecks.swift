import Foundation

@main
struct TottiDeliveryChecks {
    static func main() {
        for type in ["totti_mic_ack", "totti_listening", "totti_processing", "totti_user", "totti_answer", "totti_error", "totti_audio_error", "totti_session_end", "totti_turn_done", "totti_pong"] {
            precondition(TottiDeliveryPolicy.shouldSend(type), "Required message filtered: \(type)")
        }
        precondition(!TottiDeliveryPolicy.shouldSend("totti_capture_info"))
        precondition(!TottiDeliveryPolicy.shouldSend("totti_audio_status"))
        precondition(TottiDeliveryPolicy.silenceSeconds == 2)
        for text in ["バイバイ", "ばいばい。", " バイバイ！ ", "会話を終了して", "Bye-bye", "bye bye", "BYE-BYE!", "바이바이", "拜拜", "再见", "じゃあ、バイバイ", "ﾊﾞｲﾊﾞｲ"] {
            precondition(TottiDeliveryPolicy.isExitPhrase(text))
        }
        for text in ["バイバイって何？", "この作業は終わり？", "終了時刻を教えて", "まだ終了しない", ""] {
            precondition(!TottiDeliveryPolicy.isExitPhrase(text))
        }
        var session = TottiSessionPolicy()
        precondition(session.accept("one"))
        session.end()
        precondition(session.ended)
        precondition(!session.accept("one"))
        precondition(session.accept("two"))
        precondition(!session.accept("one"))
        precondition(!session.ended)
        session.end()
        precondition(!session.accept("two"))
        var conversation = TottiConversationPolicy()
        precondition(conversation.takeSilencePrompt() != nil)
        for _ in 0..<100 { precondition(conversation.takeSilencePrompt() == nil) }
        conversation.recognizedSpeech()
        precondition(conversation.takeSilencePrompt() != nil)
        precondition(TottiConversationPolicy.isNoSpeechResponse(user: "", answer: "音声を認識できませんでした。"))
        precondition(!TottiConversationPolicy.isNoSpeechResponse(user: "エラーを説明して", answer: "音声を認識できませんでした"))
        precondition(!TottiConversationPolicy.isNoSpeechResponse(user: "", answer: "音声認識でエラーが発生しました"))
        var retries = TottiCompletionRetryPolicy()
        let old = retries.revision
        precondition(retries.isCurrent(old))
        retries.invalidate()
        precondition(!retries.isCurrent(old))
        let fresh = retries.revision
        precondition(retries.isCurrent(fresh))
        retries.invalidate()
        precondition(!retries.isCurrent(fresh))
        print("PASS: required HUD/control/error messages retained; diagnostic traffic filtered; stale completion retry cancelled")
    }
}
