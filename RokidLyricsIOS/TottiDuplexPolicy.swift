import Foundation

/// Pure PCM segmentation, independent of the audio route and network.
/// 16 kHz mono signed little-endian PCM. Keep 350 ms before speech detection.
struct TottiDuplexSegmenter {
    enum Event { case began, ended(Data) }
    private var preRoll = Data()
    private var pcm = Data()
    private var voicedSeconds = 0.0
    private var quietSeconds = 0.0
    private(set) var speaking = false
    mutating func append(_ bytes: Data) -> [Event] {
        guard bytes.count >= 2 else { return [] }
        let duration = Double(bytes.count / 2) / 16000
        var squares = 0.0
        bytes.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: b.count - 1, by: 2) {
                let v = Double(Int16(bitPattern: UInt16(b[i]) | UInt16(b[i+1]) << 8)) / 32768
                squares += v * v
            }
        }
        let loud = sqrt(squares / Double(bytes.count / 2)) >= 0.01
        if !speaking {
            preRoll.append(bytes)
            if preRoll.count > 11200 { preRoll.removeFirst(preRoll.count - 11200) }
            voicedSeconds = loud ? voicedSeconds + duration : 0
            guard voicedSeconds >= 0.18 else { return [] }
            speaking = true; quietSeconds = 0; pcm = preRoll; preRoll.removeAll(keepingCapacity: true)
            return [.began]
        }
        pcm.append(bytes)
        quietSeconds = loud ? 0 : quietSeconds + duration
        if quietSeconds >= TottiDeliveryPolicy.silenceSeconds || pcm.count >= 16000 * 2 * 30 {
            return finish()
        }
        return []
    }
    mutating func finish() -> [Event] {
        guard speaking else { return [] }
        var buffer = TottiPCMBuffer()
        buffer.append(pcm, at: 0)
        let wav = buffer.wav()
        self = Self()
        return [.ended(wav)]
    }
}

/// A reply is valid until its session closes, even when newer speech has begun.
struct TottiDuplexTurns {
    private(set) var pending = Set<String>()
    private(set) var closed = false
    mutating func insert(_ id: String) -> Bool {
        guard !closed else { return false }
        return pending.insert(id).inserted
    }
    mutating func complete(_ id: String) -> Bool { !closed && pending.remove(id) != nil }
    func contains(_ id: String) -> Bool { !closed && pending.contains(id) }
    mutating func close() { closed = true; pending.removeAll() }
}

/// Duplicate SDK deliveries and Android retries must not flood the control link.
struct TottiStartReplyPolicy {
    private var lastAcceptedAt = -Double.infinity
    private var announcedReady = false
    mutating func shouldAcknowledge(at now: TimeInterval) -> Bool {
        guard now - lastAcceptedAt >= 10 else { return false }
        lastAcceptedAt = now
        return true
    }
    mutating func shouldAnnounceReady() -> Bool {
        guard !announcedReady else { return false }
        announcedReady = true
        return true
    }
}
