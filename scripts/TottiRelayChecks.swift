import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@MainActor final class TottiSpeechPlayer {
    var reportEvent: ((String, String) -> Void)?
    var playing: String?; var played: [String] = []; var cancelled: [String] = []
    func cancel(requestID: String) { cancelled.append(requestID); if playing == requestID { playing = nil } }
    func speak(_ text: String, requestID: String, completed: (() -> Void)?, report: @escaping (String,String)->Void) { reportEvent = report; playing = requestID; played.append(text) }
}
@MainActor enum TottiConversationAudio { static func end() {} }
@MainActor final class MockNetwork {
    var requests: [(URLRequest, CheckedContinuation<(Data, URLResponse), Error>)] = []
    func run(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { requests.append((request, $0)) }
    }
    func respond(_ index: Int, body: String, type: String) {
        let request = requests[index].0
        requests[index].1.resume(returning: (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":type])!))
    }
}
@main struct Test {
    @MainActor static func settle() async { for _ in 0..<20 { await Task.yield() } }
    @MainActor static func main() async {
        let noSpeech = Data("data: {\"type\":\"answer\",\"text\":\"音声を認識できませんでした\"}\n\ndata: {\"type\":\"done\"}\n".utf8)
        let empty = try! TottiVoiceRelay.decodeTranscription(noSpeech, contentType: "text/event-stream")
        precondition(empty.user.isEmpty && empty.completed == nil)
        let json = try! TottiVoiceRelay.decodeTranscription(Data("{\"text\":\"こんにちは\"}".utf8), contentType: "application/json; charset=utf-8")
        precondition(json.user == "こんにちは")
        do {
            _ = try TottiVoiceRelay.decodeTranscription(Data("not json".utf8), contentType: "application/json")
            fatalError("Malformed JSON accepted")
        } catch { precondition(error.localizedDescription.contains("応答形式")) }
        let net = MockNetwork(), speech = TottiSpeechPlayer()
        var events: [[String:Any]] = []
        let relay = TottiVoiceRelay(send: { events.append($0) }, speech: speech, performRequest: { try await net.run($0) })
        precondition(relay.acceptSession("session")); relay.beginContinuous("control")
        relay.speechBegan(); relay.submitContinuous(Data(repeating: 0, count: 100))
        await settle(); precondition(net.requests.count == 1)
        net.respond(0, body: "{\"text\":\"最初の質問\"}", type:"application/json")
        await settle(); precondition(net.requests.count == 2)
        relay.speechBegan(); relay.submitContinuous(Data(repeating: 0, count: 100))
        await settle(); precondition(net.requests.count == 3)
        net.respond(2, body: "{\"text\":\"次の質問\"}", type:"application/json")
        await settle(); precondition(net.requests.count == 4)
        net.respond(3, body: "data: {\"type\":\"answer\",\"text\":\"新しい回答\"}\n\ndata: {\"type\":\"done\"}\n", type:"text/event-stream")
        await settle(); precondition(speech.played == ["新しい回答"])
        let lastRealHUD = relay.lastHUDSendAt
        speech.reportEvent?("totti_audio_status", "local diagnostic")
        precondition(relay.lastHUDSendAt == lastRealHUD) // Local logs must not suppress watchdog heartbeat.

        relay.speechBegan() // Interrupt newer TTS; older HTTP remains in flight.
        precondition(speech.cancelled.count == 1)
        net.respond(1, body: "data: {\"type\":\"answer\",\"text\":\"遅れた回答\"}\n\ndata: {\"type\":\"done\"}\n", type:"text/event-stream")
        await settle()
        let answers = events.filter { $0["type"] as? String == "totti_answer" }
        precondition(answers.count == 2 && answers[1]["message"] as? String == "遅れた回答")
        precondition(answers[0]["turn_id"] as? String != answers[1]["turn_id"] as? String)
        precondition(speech.played.count == 1) // User speaking: display but don't overlap TTS.
        relay.submitContinuous(Data(repeating: 0, count: 100)); await settle()
        precondition(net.requests.count == 5)
        net.respond(4, body: "{\"text\":\"Bye-bye\"}", type:"application/json"); await settle()
        precondition(relay.sessionEnded)
        precondition(events.contains { $0["type"] as? String == "totti_session_end" })
        precondition(!relay.acceptSession("session"))
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        print("PASS relay: concurrent requests, late answer displayed, mapped IDs, speech interrupted, no TTS over user speech, bye termination, closed-session rejection")
    }
}
