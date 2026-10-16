import Foundation
@main struct TottiDuplexChecks { static func main() {
func pcm(_ value: Int16, milliseconds: Int) -> Data {
    var data = Data()
    let word = UInt16(bitPattern: value)
    for _ in 0..<(milliseconds * 16) { data.append(UInt8(word & 255)); data.append(UInt8(word >> 8)) }
    return data
}
var checks = 0
func check(_ ok: @autoclosure () -> Bool, _ label: String) {
    precondition(ok(), label); checks += 1; print("PASS \(label)")
}
var gate = TottiDuplexSegmenter()
check(gate.append(pcm(0, milliseconds: 1000)).isEmpty, "silence is not speech")
check(gate.append(pcm(1000, milliseconds: 100)).isEmpty, "brief noise not accepted")
_ = gate.append(pcm(0, milliseconds: 100))
check(gate.append(pcm(1000, milliseconds: 100)).isEmpty, "voiced threshold resets across silence")
let begin = gate.append(pcm(1000, milliseconds: 100))
check(begin.count == 1 && gate.speaking, "sustained speech starts capture")
check(gate.append(pcm(0, milliseconds: 1000)).isEmpty, "short pause preserves sentence")
let result = gate.append(pcm(0, milliseconds: 1000))
check(result.count == 1 && !gate.speaking, "two seconds silence closes utterance")
if case .ended(let wav) = result[0] {
    check(String(data: wav.prefix(4), encoding: .utf8) == "RIFF", "valid WAV header")
    check(wav.count == 44 + 11200 + 64000, "pre-roll and silence preserved")
} else { fatalError("wrong event") }
check(gate.finish().isEmpty, "duplicate stop cannot send duplicate audio")
_ = gate.append(pcm(1000, milliseconds: 200))
check(gate.append(pcm(1000, milliseconds: 30000)).count == 1, "long utterance bounded")
var turns = TottiDuplexTurns()
check(turns.insert("older"), "first HTTP turn accepted")
check(turns.insert("newer"), "new speech keeps old request")
check(!turns.insert("older"), "duplicate request rejected")
check(turns.complete("newer"), "new answer can arrive first")
check(turns.contains("older") && turns.complete("older"), "late answer retained")
_ = turns.insert("pending"); turns.close()
check(!turns.complete("pending") && !turns.insert("after-bye"), "bye closes all old turns")
for text in ["バイバイ", "Bye-bye", "바이바이", "拜拜"] { check(TottiDeliveryPolicy.isExitPhrase(text), "exit \(text)") }
check(!TottiDeliveryPolicy.isExitPhrase("バイバイってどういう意味？"), "ordinary question not exit")
print("\(checks) checks passed")

} }
