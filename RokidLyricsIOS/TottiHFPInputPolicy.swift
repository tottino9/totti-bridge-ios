import Foundation

// Pure policy, also tested without AVFoundation. Never select an iPhone microphone.
enum TottiHFPInputPolicy {
    struct Input: Equatable { let uid: String; let name: String; let isHFP: Bool }
    enum Failure: LocalizedError {
        case missing(String), ambiguous(String)
        var errorDescription: String? {
            switch self {
            case .missing(let names): return "眼鏡のBluetoothマイクが見つかりません（HFP入力: \(names)）。iPhone本体のマイクには切り替えません。"
            case .ambiguous(let names): return "眼鏡のマイク候補が複数あります: \(names)"
            }
        }
    }
    static func choose(_ inputs: [Input]) throws -> Input {
        let hfp = inputs.filter { $0.isHFP }
        let glasses = hfp.filter {
            let name = $0.name.lowercased()
            return name.contains("rokid") || name.contains("glasses")
        }
        guard !glasses.isEmpty else {
            throw Failure.missing(hfp.map { $0.name }.joined(separator: ", ").isEmpty ? "なし" : hfp.map { $0.name }.joined(separator: ", "))
        }
        guard glasses.count == 1 else { throw Failure.ambiguous(glasses.map { $0.name }.joined(separator: ", ")) }
        return glasses[0]
    }
    static func matchesActual(_ actual: [Input], selectedUID: String) -> Bool {
        actual.contains { $0.isHFP && $0.uid == selectedUID }
    }
}

enum TottiHFPWave {
    enum Failure: Error { case invalid, unsupported, truncated, tooShort }
    // Validate the recorder's finished WAV, including variable-sized/padded chunks.
    static func validate(_ data: Data) throws -> Int {
        let b = Array(data)
        guard b.count >= 44, b.count <= 2_000_000,
              Array(b[0..<4]) == Array("RIFF".utf8), Array(b[8..<12]) == Array("WAVE".utf8) else { throw Failure.invalid }
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
        let end = u32(4) + 8
        guard end >= 12, end <= b.count else { throw Failure.truncated }
        var p = 12, validFormat = false, pcmBytes = 0, seenFormat = false, seenData = false
        while p + 8 <= end {
            let name = Array(b[p..<(p + 4)]), count = u32(p + 4), start = p + 8
            guard count <= end - start else { throw Failure.truncated }
            if name == Array("fmt ".utf8) {
                guard !seenFormat, count >= 16 else { throw Failure.invalid }
                seenFormat = true
                validFormat = u16(start) == 1 && u16(start + 2) == 1 && u32(start + 4) == 16000 && u32(start + 8) == 32000 && u16(start + 12) == 2 && u16(start + 14) == 16
            }
            if name == Array("data".utf8) {
                guard !seenData else { throw Failure.invalid }
                seenData = true; pcmBytes = count
            }
            p = start + count + (count % 2)
        }
        guard p == end else { throw Failure.truncated }
        guard validFormat && seenData else { throw Failure.unsupported }
        guard pcmBytes >= 6400 && pcmBytes % 2 == 0 else { throw Failure.tooShort }
        return pcmBytes
    }
}
