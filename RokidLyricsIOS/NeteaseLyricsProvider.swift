import CommonCrypto
import Foundation
import Security

struct NeteaseLyricsProvider: LyricsProvider {
    let providerName = "NETEASE"
    var session: URLSession = .shared

    func fetch(_ request: LyricsLookupRequest) async -> LyricsProviderAttempt {
        do {
            guard let candidate = try await resolveBestTrack(request) else {
                return .noMatch(provider: providerName, reason: "No Netease match with synced lyrics for \(request.title) by \(request.artist).")
            }
            guard let payload = try await fetchLyricPayload(trackId: candidate.trackId) else {
                return .noMatch(provider: providerName, reason: "Netease found the track but no lyrics payload was available.")
            }
            let parsed = parseLyricPayload(payload)
            guard !parsed.lines.isEmpty else {
                return .noMatch(provider: providerName, reason: parsed.failureReason ?? "Netease lyrics payload could not be parsed into timed lines.")
            }
            return .success(
                LyricsFetchResult(
                    trackTitle: candidate.trackName.ifBlank(request.title),
                    artistName: candidate.artistName.ifBlank(request.artist),
                    albumName: candidate.albumName.ifBlank(request.album),
                    durationSeconds: candidate.durationSeconds ?? request.durationSeconds,
                    provider: providerName,
                    synced: true,
                    lines: parsed.lines,
                    plainLyrics: "",
                    sourceSummary: "Synced lyrics loaded from Netease \(parsed.sourceLabel) with \(parsed.lines.count) timed lines."
                )
            )
        } catch {
            return .noMatch(provider: providerName, reason: error.localizedDescription)
        }
    }

    private func resolveBestTrack(_ request: LyricsLookupRequest) async throws -> NeteaseTrack? {
        let prepared = PreparedLookupRequest(request: request)
        var candidates: [NeteaseTrack] = []
        for query in prepared.searchQueries {
            candidates.append(contentsOf: try await searchTracks(query: query))
        }
        return pickSearchCandidate(candidates, prepared: prepared, request: request)
    }

    private func searchTracks(query: String) async throws -> [NeteaseTrack] {
        if let tracks = try? await officialSearchTracks(query: query) {
            return tracks
        }
        return try await legacySearchTracks(query: query)
    }

    private func officialSearchTracks(query: String) async throws -> [NeteaseTrack]? {
        let json = try await postWeapiJSON(
            url: Self.officialSearchURL,
            payload: [
                "csrf_token": "",
                "s": query,
                "offset": 0,
                "type": 1,
                "limit": Self.searchLimit
            ]
        )
        guard json.int("code") == 200 else { return nil }
        let result = json["result"] as? [String: Any]
        let songs = result?["songs"] as? [[String: Any]] ?? []
        return songs.compactMap { $0.toNeteaseTrack() }
    }

    private func legacySearchTracks(query: String) async throws -> [NeteaseTrack] {
        var components = URLComponents(string: "https://music.163.com/api/search/get/")!
        components.queryItems = [
            URLQueryItem(name: "csrf_token", value: ""),
            URLQueryItem(name: "hlpretag", value: ""),
            URLQueryItem(name: "hlposttag", value: ""),
            URLQueryItem(name: "s", value: query),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "total", value: "true"),
            URLQueryItem(name: "limit", value: "10")
        ]
        let json = try await getJSON(url: components.url!, extraHeaders: [:])
        guard json.int("code") == 200 else { return [] }
        let result = json["result"] as? [String: Any]
        let songs = result?["songs"] as? [[String: Any]] ?? []
        return songs.compactMap { $0.toNeteaseTrack() }
    }

    private func fetchLyricPayload(trackId: Int64) async throws -> NeteaseLyricPayload? {
        if let payload = try? await officialLyricPayload(trackId: trackId) {
            return payload
        }
        return try await legacyLyricPayload(trackId: trackId)
    }

    private func officialLyricPayload(trackId: Int64) async throws -> NeteaseLyricPayload? {
        let json = try await postWeapiJSON(
            url: Self.officialLyricURL,
            payload: [
                "OS": "pc",
                "id": trackId,
                "lv": -1,
                "kv": -1,
                "tv": -1,
                "rv": -1
            ]
        )
        guard json.int("code") == 200 else { return nil }
        return lyricPayload(from: json)
    }

    private func legacyLyricPayload(trackId: Int64) async throws -> NeteaseLyricPayload? {
        var components = URLComponents(string: "https://music.163.com/api/song/lyric")!
        components.queryItems = [
            URLQueryItem(name: "os", value: "pc"),
            URLQueryItem(name: "id", value: String(trackId)),
            URLQueryItem(name: "lv", value: "-1"),
            URLQueryItem(name: "kv", value: "-1"),
            URLQueryItem(name: "tv", value: "-1")
        ]
        let json = try await getJSON(url: components.url!, extraHeaders: ["Cookie": "appver=1.5.0.75771;"])
        guard json.int("code") == 200 else { return nil }
        return lyricPayload(from: json)
    }

    private func lyricPayload(from json: [String: Any]) -> NeteaseLyricPayload {
        return NeteaseLyricPayload(
            lrc: ((json["lrc"] as? [String: Any])?["lyric"] as? String).orEmpty,
            klyric: ((json["klyric"] as? [String: Any])?["lyric"] as? String).orEmpty,
            unavailableHint: json.truthy("nolyric") || json.truthy("uncollected"),
            instrumentalHint: json.truthy("pureMusic")
        )
    }

    private func postWeapiJSON(url: String, payload: [String: Any]) async throws -> [String: Any] {
        let requestJSON = try Self.jsonString(payload)
        let secretKey = Self.createSecretKey(length: Self.secretKeyLength)
        let params = try Self.aesEncode(
            Self.aesEncode(requestJSON, secret: Self.nonce),
            secret: secretKey
        )
        let encSecKey = try Self.rsaEncode(secretKey)

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "params", value: params),
            URLQueryItem(name: "encSecKey", value: encSecKey)
        ]

        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(httpCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func getJSON(url: URL, extraHeaders: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: request)
        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(httpCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func parseLyricPayload(_ payload: NeteaseLyricPayload) -> ParsedLyricPayload {
        if payload.instrumentalHint {
            return ParsedLyricPayload(lines: [], failureReason: "Netease marks this track as instrumental.")
        }
        if payload.unavailableHint {
            return ParsedLyricPayload(lines: [], failureReason: "Netease matched the track but no lyrics are available.")
        }

        let timed = parseTimedLyrics(payload.lrc)
        if !timed.isEmpty {
            return ParsedLyricPayload(lines: timed, sourceLabel: "(LRC)")
        }

        let karaoke = parseKaraokeLyrics(payload.klyric)
        if !karaoke.isEmpty {
            return ParsedLyricPayload(lines: karaoke, sourceLabel: "(karaoke)")
        }

        let hasPayload = !payload.lrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !payload.klyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ParsedLyricPayload(
            lines: [],
            failureReason: hasPayload
                ? "Netease lyrics payload could not be parsed into timed lines."
                : "Netease found the track but no lyrics payload was available."
        )
    }

    private func parseTimedLyrics(_ raw: String) -> [LyricsLine] {
        guard !raw.isEmpty else { return [] }
        let timestampRegex = try? NSRegularExpression(pattern: #"\[(\d+):(\d{2}(?:\.\d+)?)\]"#)
        return raw
            .split(whereSeparator: \.isNewline)
            .flatMap { rawLine -> [LyricsLine] in
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let timestampRegex else { return [] }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                let matches = timestampRegex.matches(in: line, range: range)
                guard !matches.isEmpty else { return [] }
                let text = timestampRegex
                    .stringByReplacingMatches(in: line, range: range, withTemplate: " ")
                    .cleanLyricText()
                guard !text.isEmpty, !Self.isCreditLine(text), !Self.isInstrumentalLine(text) else { return [] }
                return matches.compactMap { match in
                    guard let minuteRange = Range(match.range(at: 1), in: line),
                          let secondRange = Range(match.range(at: 2), in: line),
                          let minutes = Int64(line[minuteRange]),
                          let seconds = Double(line[secondRange]) else { return nil }
                    return LyricsLine(startTimeMs: minutes * 60_000 + Int64(seconds * 1000), text: text)
                }
            }
            .uniqueByTimeAndText()
    }

    private func parseKaraokeLyrics(_ raw: String) -> [LyricsLine] {
        guard !raw.isEmpty else { return [] }
        let lineRegex = try? NSRegularExpression(pattern: #"^\[(\d+),(\d+)\](.*)$"#)
        let wordRegex = try? NSRegularExpression(pattern: #"\(\d+,\d+\)"#)
        return raw
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> LyricsLine? in
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let lineRegex else { return nil }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard let match = lineRegex.firstMatch(in: line, range: range),
                      let startRange = Range(match.range(at: 1), in: line),
                      let textRange = Range(match.range(at: 3), in: line),
                      let start = Int64(line[startRange]) else { return nil }
                var text = String(line[textRange])
                if let wordRegex {
                    let textRange = NSRange(text.startIndex..<text.endIndex, in: text)
                    text = wordRegex.stringByReplacingMatches(in: text, range: textRange, withTemplate: " ")
                }
                text = text.cleanLyricText()
                guard !text.isEmpty, !Self.isCreditLine(text), !Self.isInstrumentalLine(text) else { return nil }
                return LyricsLine(startTimeMs: start, text: text)
            }
            .uniqueByTimeAndText()
    }

    private func pickSearchCandidate(_ candidates: [NeteaseTrack], prepared: PreparedLookupRequest, request: LyricsLookupRequest) -> NeteaseTrack? {
        var seen = Set<Int64>()
        return candidates
            .filter { seen.insert($0.trackId).inserted }
            .compactMap { candidate in
                candidateScore(candidate, prepared: prepared, request: request).map { (candidate, $0) }
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    private func candidateScore(_ candidate: NeteaseTrack, prepared: PreparedLookupRequest, request: LyricsLookupRequest) -> Int? {
        let titleScore = max(
            TextMatch.score(request: prepared.titleForMatch, candidate: candidate.trackName),
            TextMatch.score(request: request.title, candidate: candidate.trackName)
        )
        let artistScore = max(
            TextMatch.score(request: prepared.artistForMatch, candidate: candidate.artistName),
            TextMatch.score(request: request.artist, candidate: candidate.artistName)
        )
        guard titleScore >= 55, artistScore >= 40 else { return nil }

        var score = titleScore * 3 + artistScore * 2
        if !request.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += TextMatch.score(request: request.album, candidate: candidate.albumName) / 2
        }
        if let requestDuration = request.durationSeconds, let candidateDuration = candidate.durationSeconds {
            let delta = abs(requestDuration - candidateDuration)
            switch delta {
            case 0...1: score += 25
            case 2...3: score += 15
            case 4...6: score += 5
            case 30...: score -= 65
            case 20...: score -= 40
            default: score -= 10
            }
        }
        if TextMatch.comparable(prepared.titleForMatch) == TextMatch.comparable(candidate.trackName) { score += 40 }
        if TextMatch.comparable(prepared.artistForMatch) == TextMatch.comparable(candidate.artistName) { score += 30 }
        score -= variantPenalty(requestTitle: request.title, candidateTitle: candidate.trackName, candidateAlbum: candidate.albumName)
        return score
    }

    private func variantPenalty(requestTitle: String, candidateTitle: String, candidateAlbum: String) -> Int {
        let requestHasVariant = requestTitle.range(of: Self.variantRegex, options: [.regularExpression, .caseInsensitive]) != nil
        var penalty = 0
        if !requestHasVariant && candidateTitle.range(of: Self.variantRegex, options: [.regularExpression, .caseInsensitive]) != nil {
            penalty += 55
        }
        if !requestHasVariant && candidateAlbum.range(of: Self.variantRegex, options: [.regularExpression, .caseInsensitive]) != nil {
            penalty += 20
        }
        return penalty
    }

    private static func isCreditLine(_ text: String) -> Bool {
        creditPrefixes.contains { text.lowercased().hasPrefix($0) }
    }

    private static func isInstrumentalLine(_ text: String) -> Bool {
        instrumentalMarkers.contains { text.caseInsensitiveCompare($0) == .orderedSame }
    }

    private static func jsonString(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let value = String(data: data, encoding: .utf8) else {
            throw NeteaseCryptoError.invalidPayload
        }
        return value
    }

    private static func createSecretKey(length: Int) -> String {
        let alphabet = Array(secretKeyAlphabet)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if status != errSecSuccess {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(length).description
        }
        return String(randomBytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private static func aesEncode(_ value: String, secret: String) throws -> String {
        let data = Data(value.utf8)
        let key = Data(secret.utf8)
        let iv = Data(aesIV.utf8)
        let outputCapacity = data.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outputLength = 0

        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { dataBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress,
                            kCCKeySizeAES128,
                            ivBuffer.baseAddress,
                            dataBuffer.baseAddress,
                            data.count,
                            outputBuffer.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw NeteaseCryptoError.aesFailed(status)
        }
        output.removeSubrange(outputLength..<output.count)
        return output.base64EncodedString()
    }

    private static func rsaEncode(_ value: String) throws -> String {
        guard let publicKey = rsaPublicKey else {
            throw NeteaseCryptoError.rsaKeyCreationFailed
        }
        let reversed = String(value.reversed())
        guard let data = reversed.data(using: .utf8) else {
            throw NeteaseCryptoError.invalidPayload
        }
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionRaw, data as CFData, &error) as Data? else {
            throw NeteaseCryptoError.rsaFailed(error?.takeRetainedValue())
        }
        return encrypted.hexLowercased()
    }

    private static let rsaPublicKey: SecKey? = {
        let modulus = hexBytes(rsaModulusHex)
        let exponent = hexBytes(rsaPublicExponentHex)
        let keyData = derSequence(derInteger(modulus) + derInteger(exponent))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: rsaKeySizeBits
        ]
        return SecKeyCreateWithData(Data(keyData) as CFData, attributes as CFDictionary, nil)
    }()

    private static func hexBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        return bytes
    }

    private static func derSequence(_ content: [UInt8]) -> [UInt8] {
        [0x30] + derLength(content.count) + content
    }

    private static func derInteger(_ value: [UInt8]) -> [UInt8] {
        var normalized = value
        while normalized.count > 1,
              normalized[0] == 0,
              (normalized[1] & 0x80) == 0 {
            normalized.removeFirst()
        }
        if let first = normalized.first, (first & 0x80) != 0 {
            normalized.insert(0, at: 0)
        }
        return [0x02] + derLength(normalized.count) + normalized
    }

    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 128 {
            return [UInt8(length)]
        }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static let officialSearchURL = "https://music.163.com/weapi/search/get"
    private static let officialLyricURL = "https://music.163.com/weapi/song/lyric?csrf_token="
    private static let searchLimit = 20
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    private static let variantRegex = "\\b(remix|live|cover|instrumental|inst|version|ver|bootleg|edit)\\b|\u{4f34}\u{594f}|\u{7ffb}\u{5531}|\u{539f}\u{5531}|\u{7248}|\u{73b0}\u{573a}|dj"
    private static let secretKeyLength = 16
    private static let secretKeyAlphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let nonce = "0CoJUm6Qyw8W8jud"
    private static let aesIV = "0102030405060708"
    private static let rsaKeySizeBits = 1024
    private static let rsaPublicExponentHex = "010001"
    private static let rsaModulusHex = "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7"
    private static let creditPrefixes = [
        "\u{4f5c}\u{8bcd}", "\u{4f5c}\u{66f2}", "\u{7f16}\u{66f2}", "\u{5236}\u{4f5c}\u{4eba}",
        "\u{76d1}\u{5236}", "\u{6df7}\u{97f3}", "\u{6bcd}\u{5e26}", "\u{548c}\u{58f0}", "\u{5f55}\u{97f3}",
        "lyrics by", "written by", "composed by", "arranged by", "producer", "composer",
        "lyricist", "mixing", "mastering", "recording", "engineer", "vocals", "artist"
    ]
    private static let instrumentalMarkers = [
        "\u{7eaf}\u{97f3}\u{4e50}\u{ff0c}\u{8bf7}\u{6b23}\u{8d4f}",
        "\u{7d14}\u{97f3}\u{6a02}\u{ff0c}\u{8acb}\u{6b23}\u{8cde}",
        "instrumental"
    ]
}

private enum NeteaseCryptoError: Error {
    case invalidPayload
    case aesFailed(CCCryptorStatus)
    case rsaKeyCreationFailed
    case rsaFailed(CFError?)
}

private struct NeteaseTrack: Equatable {
    var trackId: Int64
    var trackName: String
    var artistName: String
    var albumName: String
    var durationSeconds: Int?
}

private struct NeteaseLyricPayload: Equatable {
    var lrc: String
    var klyric: String
    var unavailableHint: Bool
    var instrumentalHint: Bool
}

private struct ParsedLyricPayload: Equatable {
    var lines: [LyricsLine]
    var sourceLabel: String = ""
    var failureReason: String?
}

private struct PreparedLookupRequest: Equatable {
    var titleForMatch: String
    var artistForMatch: String
    var searchQueries: [String]

    init(request: LyricsLookupRequest) {
        let title = request.title.sanitizedMusicText()
        let artist = request.artist.sanitizedMusicText()
        let titleParts = Self.extractFeat(title)
        let artistParts = Self.extractFeat(artist)
        titleForMatch = titleParts.base.ifBlank(title)
        let artists = (Self.splitArtists(artistParts.base) + titleParts.featured + artistParts.featured)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        artistForMatch = artists.joined(separator: " ").ifBlank(artist)

        var queries = [
            request.title.trimmingCharacters(in: .whitespacesAndNewlines),
            titleForMatch,
            "\(titleForMatch) \(artistForMatch)".trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        if !request.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queries.append("\(titleForMatch) \(artistForMatch) \(request.album)".trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var seen = Set<String>()
        searchQueries = queries.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func extractFeat(_ value: String) -> (base: String, featured: [String]) {
        let patterns = [#"\s*\(feat(.+)\)"#, #"\s+feat(.+)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = regex.firstMatch(in: value, range: range),
                  let matchRange = Range(match.range, in: value),
                  let featRange = Range(match.range(at: 1), in: value) else { continue }
            let base = value.replacingCharacters(in: matchRange, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let featured = splitArtists(String(value[featRange]).trimmingCharacters(in: CharacterSet(charactersIn: ". )")))
            return (base, featured)
        }
        return (value, [])
    }

    private static func splitArtists(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: "/&,\u{ff0c}\u{00d7}\u{00b7}"))
            .flatMap { $0.components(separatedBy: " x ") }
            .flatMap { $0.components(separatedBy: " * ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func toNeteaseTrack() -> NeteaseTrack? {
        guard let id = int64("id") ?? int("id").map(Int64.init) else { return nil }
        let artistList = (self["artists"] as? [[String: Any]]) ?? (self["ar"] as? [[String: Any]]) ?? []
        let artists = artistList.map { $0.string("name") }.filter { !$0.isEmpty }.joined(separator: ", ")
        let album = (self["album"] as? [String: Any]) ?? (self["al"] as? [String: Any])
        let durationMs = int("duration") ?? int("dt")
        return NeteaseTrack(
            trackId: id,
            trackName: string("name"),
            artistName: artists,
            albumName: album?.string("name") ?? "",
            durationSeconds: durationMs.map { $0 / 1000 }
        )
    }
}

private extension Array where Element == LyricsLine {
    func uniqueByTimeAndText() -> [LyricsLine] {
        var seen = Set<String>()
        return filter { line in
            seen.insert("\(line.startTimeMs)|\(line.text)").inserted
        }
    }
}

private extension Data {
    func hexLowercased() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
