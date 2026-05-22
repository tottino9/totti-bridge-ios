import Foundation

enum LrcParser {
    private static let timestampPattern = #"^\[(\d+):(\d{2}(?:\.\d+)?)\](.*)$"#

    static func parseSyncedLyrics(_ raw: String) -> [LyricsLine] {
        let regex = try? NSRegularExpression(pattern: timestampPattern)
        return raw
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine in
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, let regex else { return nil }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard let match = regex.firstMatch(in: line, range: range),
                      match.numberOfRanges == 4,
                      let minuteRange = Range(match.range(at: 1), in: line),
                      let secondRange = Range(match.range(at: 2), in: line),
                      let textRange = Range(match.range(at: 3), in: line),
                      let minutes = Int64(line[minuteRange]),
                      let seconds = Double(line[secondRange])
                else {
                    return nil
                }

                let text = String(line[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                return LyricsLine(
                    startTimeMs: minutes * 60_000 + Int64(seconds * 1000),
                    text: text.isEmpty ? "(instrumental)" : text
                )
            }
            .sorted { $0.startTimeMs < $1.startTimeMs }
    }

    static func index(for lines: [LyricsLine], progressMs: Int64) -> Int {
        guard !lines.isEmpty else { return -1 }
        var candidate = -1
        for (index, line) in lines.enumerated() {
            if line.startTimeMs <= progressMs {
                candidate = index
            } else {
                break
            }
        }
        return candidate
    }
}

enum TextMatch {
    static func score(request: String, candidate: String) -> Int {
        let normalizedRequest = comparable(request)
        let normalizedCandidate = comparable(candidate)
        if normalizedRequest.isEmpty || normalizedCandidate.isEmpty { return 0 }
        if normalizedRequest == normalizedCandidate { return 100 }
        if normalizedCandidate.contains(normalizedRequest) || normalizedRequest.contains(normalizedCandidate) {
            return 88
        }

        let requestTokens = Set(normalizedRequest.split(separator: " ").map(String.init))
        let candidateTokens = Set(normalizedCandidate.split(separator: " ").map(String.init))
        if requestTokens.isEmpty || candidateTokens.isEmpty { return 0 }

        let shared = requestTokens.intersection(candidateTokens).count
        if shared == 0 { return 0 }
        return Int((Double(shared) / Double(max(requestTokens.count, candidateTokens.count)) * 100.0).rounded())
    }

    static func comparable(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(feat|ft|featuring)\.?\b.*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
