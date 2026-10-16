import Foundation

// Test double: the production Worker/TTS relay is intentionally not invoked here.
@MainActor
final class TottiVoiceRelay {
    var isBusy = false
    var submitted: [(String, Data)] = []
    func submitCaptured(_ id: String, wav: Data) { submitted.append((id, wav)); isBusy = true }
    func cancelCaptured(_ id: String) { isBusy = false }
    func connectionLost() { isBusy = false }
}

enum CheckError: Error { case failed(String) }
@main
struct TottiCaptureChecks {
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) throws {
        if !ok() { throw CheckError.failed(message) }
    }
    @MainActor
    static func main() async throws {
        var pcm = TottiPCMBuffer()
        pcm.append(Data([0x00]), at: 1)
        pcm.append(Data([0x80, 0x00, 0x40]), at: 2)
        try check(pcm.data == Data([0x00, 0x80, 0x00, 0x40]), "unaligned PCM packets corrupt samples")
        try check(pcm.hasSpeech && pcm.peak == 1, "signed PCM16 peak / VAD")
        let wav = pcm.wav()
        try check(wav.count == 48 && wav.prefix(4) == Data("RIFF".utf8), "WAV size / magic")
        try check(Array(wav[24..<28]) == [0x80, 0x3e, 0, 0], "WAV 16000 Hz header")
        pcm.channels = 2
        try check(Array(pcm.wav()[22..<24]) == [2, 0], "stereo WAV channel header")

        let relay = TottiVoiceRelay()
        var sent: [[String: Any]] = []
        var starts = 0, stops = 0
        let capture = TottiCxrAudioCapture(send: { sent.append($0) },
            start: { starts += 1; return nil }, stop: { stops += 1; return nil }, relay: relay)
        func command(_ type: String, _ id: String) { _ = capture.handle(["type": type, "request_id": id]) }
        command("totti_mic_start", "turn1"); command("totti_mic_start", "turn1")
        try check(starts == 1, "duplicate start opened two streams")
        capture.started(codec: 1, expectedPCM: 1, channels: 1, type: "asr")
        capture.receive(Data(repeating: 0x20, count: 16000))
        command("totti_mic_stop", "turn1"); command("totti_mic_stop", "turn1")
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(relay.submitted.count == 1 && stops == 1, "duplicate stop submitted audio twice")
        try check(relay.submitted.first?.1.count == 16044, "capture WAV content length")
        command("totti_mic_start", "turn1")
        try check(starts == 1, "late duplicate reopened finished capture")
        command("totti_mic_start", "busy")
        try check(sent.contains { $0["type"] as? String == "totti_error" && $0["request_id"] as? String == "busy" }, "busy guard")
        relay.isBusy = false

        command("totti_mic_start", "cancel")
        capture.started(codec: 1, expectedPCM: 1, channels: 1, type: "asr")
        capture.receive(Data(repeating: 0x20, count: 16000))
        command("totti_mic_stop", "cancel"); command("totti_mic_cancel", "cancel")
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(relay.submitted.count == 1, "cancelled drain uploaded audio")

        command("totti_mic_start", "format")
        capture.started(codec: 99, expectedPCM: 1, channels: 1, type: "asr")
        capture.receive(Data(repeating: 0x20, count: 16000))
        command("totti_mic_stop", "format")
        try check(relay.submitted.count == 1, "invalid codec uploaded audio")

        command("totti_mic_start", "empty"); command("totti_mic_stop", "empty")
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(relay.submitted.count == 1, "empty recording uploaded audio")
        command("totti_mic_start", "disconnect"); capture.connectionLost()
        try check(sent.contains { $0["request_id"] as? String == "disconnect" && $0["type"] as? String == "totti_error" }, "disconnect not reported")
        print("PASS: PCM/WAV, duplicate control, busy, cancellation, codec, empty recording, disconnect")
    }
}
