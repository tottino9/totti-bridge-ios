import Foundation

/// Pure PCM segmentation, independent of the audio route and network.
/// 16 kHz mono signed little-endian PCM. Keep 450 ms before speech detection.
struct TottiDuplexSegmenter {
    enum Event { case began, ended(Data) }
    // Preserve pauses up to 1.2 s; avoid the old unconditional 2 s tail.
    static let endSilenceSeconds: TimeInterval = 1.2
    private var preRoll = Data()
    private var pcm = Data()
    private struct Evidence { var duration: Double; let voiced: Bool }
    private var evidence: [Evidence] = []
    private var evidenceDuration = 0.0
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
            if preRoll.count > 14400 { preRoll.removeFirst(preRoll.count - 14400) }
            evidence.append(Evidence(duration: duration, voiced: loud))
            evidenceDuration += duration
            while evidenceDuration > 0.4 && !evidence.isEmpty {
                let excess = evidenceDuration - 0.4
                if evidence[0].duration <= excess + 0.000001 {
                    evidenceDuration -= evidence.removeFirst().duration
                } else {
                    evidence[0].duration -= excess; evidenceDuration = 0.4
                }
            }
            // Japanese syllables contain brief unvoiced gaps. The old detector
            // reset all evidence on EVERY quiet buffer, missing natural words.
            let voicedSeconds = evidence.filter { $0.voiced }.reduce(0) { $0 + $1.duration }
            guard voicedSeconds >= 0.15 - 0.000001 else { return [] }
            speaking = true; quietSeconds = 0; pcm = preRoll; preRoll.removeAll(keepingCapacity: true)
            return [.began]
        }
        pcm.append(bytes)
        quietSeconds = loud ? 0 : quietSeconds + duration
        if quietSeconds >= Self.endSilenceSeconds || pcm.count >= 16000 * 2 * 30 {
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
    private var lastReadyAt = -Double.infinity
    private var announcedReady = false
    mutating func shouldAnnounceReady(at now: TimeInterval, retry: Bool = false) -> Bool {
        guard !announcedReady || (retry && now - lastReadyAt >= 10) else { return false }
        announcedReady = true
        lastReadyAt = now
        return true
    }
}

/// A first callback alone can be an empty/warm-up slice. Announce readiness
/// only after 200 ms of actual converted PCM; early speech is still segmented.
struct TottiInputReadiness {
    private var frames = 0
    private var announced = false
    mutating func accept(pcmBytes: Int) -> Bool {
        guard pcmBytes > 0, pcmBytes.isMultiple(of: 2), !announced else { return false }
        frames = min(3200, frames + min(3200, pcmBytes / 2))
        guard frames >= 3200 else { return false }
        announced = true
        return true
    }
}
