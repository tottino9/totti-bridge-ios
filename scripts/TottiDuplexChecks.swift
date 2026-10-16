import Foundation
@main struct TottiDuplexChecks { static func main() {
var passed = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) { precondition(value(), name); passed += 1; print("PASS \(name)") }
func pcm(_ v: Int16, ms: Int = 20) -> Data {
    var d = Data(); let w = UInt16(bitPattern:v)
    for _ in 0..<(ms * 16) { d.append(UInt8(w & 255)); d.append(UInt8(w >> 8)) }; return d
}
func feed(_ detector: inout TottiDuplexSegmenter, value: Int16, milliseconds: Int) -> [TottiDuplexSegmenter.Event] {
    var events: [TottiDuplexSegmenter.Event] = []
    for _ in 0..<(milliseconds / 20) { events += detector.append(pcm(value)) }; return events
}
var d = TottiDuplexSegmenter()
check(feed(&d,value:0,milliseconds:1000).isEmpty,"silence cannot start speech")
check(feed(&d,value:1000,milliseconds:80).isEmpty,"isolated short click rejected")
_ = feed(&d,value:0,milliseconds:500)
check(feed(&d,value:1000,milliseconds:80).isEmpty,"spaced noises do not accumulate forever")
_ = feed(&d,value:0,milliseconds:500)
// Natural syllabic speech: old consecutive180ms detector never starts here.
var began = 0
for _ in 0..<4 {
    for event in feed(&d,value:1000,milliseconds:60) { if case .began = event { began += 1 } }
    for event in feed(&d,value:0,milliseconds:40) { if case .began = event { began += 1 } }
}
check(began == 1 && d.speaking,"syllables with short gaps accepted exactly once")
check(feed(&d,value:0,milliseconds:800).isEmpty,"800ms thinking/pause remains in same utterance")
let end = feed(&d,value:0,milliseconds:400)
check(end.count == 1 && !d.speaking,"1.2second end silence closes utterance")
if case .ended(let wav) = end[0] {
    check(String(data:wav.prefix(4),encoding:.utf8) == "RIFF","WAV header")
    check(wav.count > 44+32000,"pre-roll and original sound preserved")
} else { fatalError("missing WAV") }
check(d.finish().isEmpty,"duplicate stop sends no second WAV")
_ = feed(&d,value:1000,milliseconds:160)
check(d.speaking,"new utterance accepted after previous one")
let second = d.finish();check(second.count == 1,"manual stop preserves next utterance")
var input = TottiInputReadiness()
check(!input.accept(pcmBytes:0),"empty callback never ready")
check(!input.accept(pcmBytes:1),"unaligned callback never ready")
for _ in 0..<9 { check(!input.accept(pcmBytes:640),"recording warm-up not prematurely ready") }
check(input.accept(pcmBytes:640),"200ms actual PCM allows ready")
check(!input.accept(pcmBytes:640),"ready emitted only once")
// No readiness gate is allowed to discard early speech.
var early = TottiDuplexSegmenter(), gate = TottiInputReadiness();var earlyDetected=false, readyAtDetection=false
for _ in 0..<10 {
    let ready = gate.accept(pcmBytes:640)
    for e in early.append(pcm(1000)) { if case .began = e { earlyDetected=true;readyAtDetection=ready } }
}
check(earlyDetected && !readyAtDetection,"speech before readiness announcement is retained")
var turns = TottiDuplexTurns();check(turns.insert("old") && turns.insert("new"),"independent in-flight requests")
check(turns.complete("new") && turns.complete("old"),"late replies retained")
turns.close();check(!turns.insert("after-exit"),"closed session cannot restart")
for text in ["バイバイ","Bye-bye","바이바이","拜拜"] {check(TottiDeliveryPolicy.isExitPhrase(text),"exit \(text)")}
let texts = ["こんにちは。",String(repeating:"日本語😀\n",count:1000)]
for (name,code) in TottiWireCodec.codes {
    for text in texts {
        var e:[String:Any] = ["type":name,"request_id":"0123456789abcdef","turn_id":"fedcba9876543210","message":text,"text":text,"sent_wall_ms":1792142623549]
        if code==1 {e["message"]="話しかけてください"}
        if code==9 {e["message"]="start"}
        let wire=TottiWireCodec.encode(e,negotiatedVersion:2)
        let bytes=try! JSONSerialization.data(withJSONObject:wire)
        let decoded=TottiWireCodec.decode(try! JSONSerialization.jsonObject(with:bytes) as! [String:Any])!
        check(decoded["type"] as? String == name,"wire event \(code)")
        let key=code==2 ? "text":"message"
        check(decoded[key] as? String == e[key] as? String,"wire text lossless \(code)")
        check(decoded["turn_id"] as? String == e["turn_id"] as? String,"turn mapping \(code)")
        check(TottiWireCodec.encode(e,negotiatedVersion:1)["type"] as? String == name,"legacy unmodified \(code)")
    }
}
check(TottiWireCodec.decode(["v":2,"r":"x","k":99]) == nil,"unknown code rejected")

var oldDetector = OldSegmenter(), newDetector = TottiDuplexSegmenter()
for _ in 0..<5 {
    for _ in 0..<3 { _ = oldDetector.append(pcm(1000)); _ = newDetector.append(pcm(1000)) }
    for _ in 0..<2 { _ = oldDetector.append(pcm(0)); _ = newDetector.append(pcm(0)) }
}
check(!oldDetector.speaking && newDetector.speaking, "REGRESSION: old misses 60ms voice/40ms gap; new detects it")


var startReplies = TottiStartReplyPolicy()
check(startReplies.shouldAnnounceReady(at: 0), "one initial ready")
check(!startReplies.shouldAnnounceReady(at: 4, retry: true), "no fast retry flood")
check(startReplies.shouldAnnounceReady(at: 10, retry: true), "lost ready can recover")
check(!startReplies.shouldAnnounceReady(at: 12, retry: true), "duplicate recovery throttled")

print("TOTAL \(passed) checks passed")

} }
