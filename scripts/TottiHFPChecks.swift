import Foundation

enum HFPCheckError: Error { case failed(String) }
@main
struct TottiHFPChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        if !condition() { throw HFPCheckError.failed(label) }
    }
    static func rejects(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw HFPCheckError.failed(label)
    }
    static func main() throws {
        typealias Input = TottiHFPInputPolicy.Input
        let builtIn = Input(uid: "phone", name: "iPhone Microphone", isHFP: false)
        let glasses = Input(uid: "glasses-1", name: "Glasses_1421", isHFP: true)
        let airpods = Input(uid: "airpods", name: "AirPods", isHFP: true)
        let selected = try TottiHFPInputPolicy.choose([builtIn, airpods, glasses])
        try check(selected == glasses, "glasses HFP selection")
        try rejects("built-in microphone selected") { _ = try TottiHFPInputPolicy.choose([builtIn]) }
        try rejects("unrelated HFP selected") { _ = try TottiHFPInputPolicy.choose([airpods]) }
        try rejects("name alone bypassed HFP check") { _ = try TottiHFPInputPolicy.choose([Input(uid: "fake", name: "Rokid", isHFP: false)]) }
        try rejects("ambiguous glasses accepted") { _ = try TottiHFPInputPolicy.choose([glasses, Input(uid: "g2", name: "Rokid", isHFP: true)]) }
        try check(TottiHFPInputPolicy.matchesActual([glasses], selectedUID: glasses.uid), "actual route match")
        try check(!TottiHFPInputPolicy.matchesActual([builtIn], selectedUID: glasses.uid), "phone fallback accepted")
        try check(!TottiHFPInputPolicy.matchesActual([airpods], selectedUID: glasses.uid), "different HFP UID accepted")
        var pcm = TottiPCMBuffer()
        pcm.append(Data(repeating: 0x20, count: 16000), at: 1)
        let wav = pcm.wav()
        let bytes = try TottiHFPWave.validate(wav)
        try check(bytes == 16000, "valid WAV rejected")
        try rejects("truncated WAV accepted") { _ = try TottiHFPWave.validate(Data(wav.dropLast())) }
        var wrongRate = wav; wrongRate[24] = 0
        try rejects("wrong sample rate accepted") { _ = try TottiHFPWave.validate(wrongRate) }
        var stereo = wav; stereo[22] = 2
        try rejects("unconfirmed channels accepted") { _ = try TottiHFPWave.validate(stereo) }
        var float = wav; float[20] = 3
        try rejects("float samples treated as PCM16") { _ = try TottiHFPWave.validate(float) }
        try rejects("empty WAV accepted") { _ = try TottiHFPWave.validate(TottiPCMBuffer().wav()) }
        // AVAudioRecorder may put extra, odd-sized chunks before fmt/data.
        var padded = wav
        padded.insert(contentsOf: Data([74,85,78,75,1,0,0,0,0,0]), at: 12)
        let size = UInt32(padded.count - 8)
        for i in 0..<4 { padded[4+i] = UInt8((size >> (8*i)) & 255) }
        let paddedBytes = try TottiHFPWave.validate(padded)
        try check(paddedBytes == 16000, "padded metadata chunk corrupted WAV parsing")
        print("PASS: HFP route selection, no built-in/unrelated fallback, ambiguity, actual UID, PCM WAV format/rate/channels, truncation, metadata chunks")
    }
}
