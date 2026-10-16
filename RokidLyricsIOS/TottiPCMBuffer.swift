import Foundation

/// CXR PCM16 little-endian. 16 kHz is the documented Android reference format;
/// iOS firmware format must still be confirmed on hardware. Keep it configurable.
struct TottiPCMBuffer {
    static let sampleRate = 16_000
    var channels = 1
    private(set) var data = Data()
    private var pendingByte: UInt8?
    private(set) var hasSpeech = false
    private(set) var lastSpeechAt: TimeInterval = 0
    private(set) var peak: Double = 0

    mutating func append(_ bytes: Data, at time: TimeInterval) {
        var aligned = Data()
        if let pendingByte { aligned.append(pendingByte) }
        aligned.append(bytes)
        pendingByte = aligned.count.isMultiple(of: 2) ? nil : aligned.removeLast()
        peak = 0
        aligned.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: values.count, by: 2) {
                let sample = Int16(bitPattern: UInt16(values[i]) | UInt16(values[i + 1]) << 8)
                peak = max(peak, Double(abs(Int(sample))) / 32768)
            }
        }
        if peak >= 0.025 { hasSpeech = true; lastSpeechAt = time }
        // Preserve the beginning and pauses; cap recording duration in the controller.
        data.append(aligned)
    }

    func wav() -> Data {
        let blockAlign = channels * 2
        let pcm = Data(data.prefix(data.count / blockAlign * blockAlign))
        var header = Data()
        func ascii(_ text: String) { header.append(Data(text.utf8)) }
        func u16(_ value: Int) { header.append(UInt8(value & 255)); header.append(UInt8((value >> 8) & 255)) }
        func u32(_ value: Int) { for shift in stride(from: 0, through: 24, by: 8) { header.append(UInt8((value >> shift) & 255)) } }
        ascii("RIFF"); u32(36 + pcm.count); ascii("WAVEfmt "); u32(16)
        u16(1); u16(channels); u32(Self.sampleRate); u32(Self.sampleRate * blockAlign)
        u16(blockAlign); u16(16); ascii("data"); u32(pcm.count)
        header.append(pcm)
        return header
    }
}
