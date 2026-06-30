import CommonCrypto
import CryptoKit
import Foundation

enum SpotifyLyricsSourceMode: String, CaseIterable, Identifiable {
    case backend
    case direct

    var id: String { rawValue }

    var label: String {
        switch self {
        case .backend:
            return "Backend"
        case .direct:
            return "Direct"
        }
    }
}

enum SpotifyTrackIdentifier {
    private static let pattern = #"[A-Za-z0-9]{22}"#

    static func extract(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.range(of: #"^[A-Za-z0-9]{22}$"#, options: .regularExpression) != nil {
            return trimmed
        }

        if let uriRange = trimmed.range(of: #"spotify:track:([A-Za-z0-9]{22})"#, options: .regularExpression) {
            return String(trimmed[uriRange]).split(separator: ":").last.map(String.init)
        }

        if let url = URL(string: trimmed),
           let trackIndex = url.pathComponents.firstIndex(of: "track"),
           url.pathComponents.indices.contains(trackIndex + 1) {
            let candidate = url.pathComponents[trackIndex + 1]
            if candidate.range(of: #"^[A-Za-z0-9]{22}$"#, options: .regularExpression) != nil {
                return candidate
            }
        }

        return trimmed.range(of: pattern, options: .regularExpression).map { String(trimmed[$0]) }
    }
}

enum SpotifySpDcCookie {
    static func extractValue(from input: String) -> String? {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("cookie:") {
            trimmed = String(trimmed.dropFirst("cookie:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for part in trimmed.split(separator: ";", omittingEmptySubsequences: true) {
            let pair = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equalsIndex = pair.firstIndex(of: "=") else { continue }
            let name = pair[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.lowercased() == "sp_dc" else { continue }
            let value = pair[pair.index(after: equalsIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.takeUnlessBlank()
        }

        let whitespaceSeparated = trimmed
            .split { $0.isWhitespace }
            .map(String.init)
        if let nameIndex = whitespaceSeparated.firstIndex(where: { $0.lowercased() == "sp_dc" }),
           whitespaceSeparated.indices.contains(nameIndex + 1) {
            return whitespaceSeparated[nameIndex + 1]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .takeUnlessBlank()
        }

        if trimmed.contains("=") || trimmed.contains(";") {
            return nil
        }
        return trimmed.takeUnlessBlank()
    }
}

enum SpotifyLyricsProviderError: LocalizedError, Equatable {
    case missingTrackId
    case missingBackendURL
    case missingSpDc
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case anonymousToken
    case noLineSyncedLyrics(syncType: String, lineCount: Int)

    var errorDescription: String? {
        switch self {
        case .missingTrackId:
            return "Spotify lyrics lookup requires a Spotify track ID or track URL."
        case .missingBackendURL:
            return "Configure a private Spotify lyrics backend URL first."
        case .missingSpDc:
            return "Add your own Spotify sp_dc cookie to Keychain first."
        case .invalidURL:
            return "The Spotify lyrics URL is invalid."
        case .invalidResponse:
            return "Spotify lyrics returned an invalid JSON response."
        case .httpStatus(let status):
            return "Spotify lyrics request failed with HTTP \(status)."
        case .anonymousToken:
            return "Spotify returned an anonymous web token. Refresh sp_dc from a logged-in Spotify web session."
        case .noLineSyncedLyrics(let syncType, let lineCount):
            return "Spotify returned syncType=\(syncType) with \(lineCount) timed lines; LINE_SYNCED is required."
        }
    }
}

struct SpotifyLyricsProvider: LyricsProvider {
    let providerName = "SPOTIFY"
    var mode: SpotifyLyricsSourceMode
    var backendBaseURL: String
    var spDc: String?
    var session: URLSession = .shared

    func fetch(_ request: LyricsLookupRequest) async -> LyricsProviderAttempt {
        do {
            switch mode {
            case .backend:
                return .success(try await fetchFromBackend(request))
            case .direct:
                return .success(try await fetchDirect(request))
            }
        } catch let error as SpotifyLyricsProviderError {
            switch error {
            case .missingBackendURL, .missingSpDc:
                return .disabled(provider: providerName, reason: error.localizedDescription)
            default:
                return .noMatch(provider: providerName, reason: error.localizedDescription)
            }
        } catch {
            return .noMatch(provider: providerName, reason: error.localizedDescription)
        }
    }

    func fetchTrackInput(_ input: String) async -> LyricsProviderAttempt {
        guard let trackId = SpotifyTrackIdentifier.extract(from: input) else {
            return .noMatch(provider: providerName, reason: SpotifyLyricsProviderError.missingTrackId.localizedDescription)
        }
        let request = LyricsLookupRequest(
            title: "Spotify track \(trackId)",
            artist: "",
            spotifyTrackId: trackId
        )
        return await fetch(request)
    }

    private func fetchFromBackend(_ request: LyricsLookupRequest) async throws -> LyricsFetchResult {
        guard let trackId = request.spotifyTrackId?.takeUnlessBlank() else {
            throw SpotifyLyricsProviderError.missingTrackId
        }
        let baseURL = backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else {
            throw SpotifyLyricsProviderError.missingBackendURL
        }
        guard let url = backendURL(baseURL: baseURL, trackId: trackId) else {
            throw SpotifyLyricsProviderError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = Tuning.lyricsRequestTimeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Rokid-Lyrics-iOS/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        print("[RokidLyricsSpotifyLyrics] backend lyrics_http_status=\(status) content_type=\(contentType.ifBlank("unknown"))")
        guard (200..<300).contains(status) else {
            throw SpotifyLyricsProviderError.httpStatus(status)
        }
        return try SpotifyColorLyricsParser.parse(
            data: data,
            trackId: trackId,
            request: request,
            provider: providerName,
            sourceLabel: "Spotify backend"
        )
    }

    private func fetchDirect(_ request: LyricsLookupRequest) async throws -> LyricsFetchResult {
        guard let trackId = request.spotifyTrackId?.takeUnlessBlank() else {
            throw SpotifyLyricsProviderError.missingTrackId
        }
        let cookie = SpotifySpDcCookie.extractValue(from: spDc ?? "") ?? ""
        guard !cookie.isEmpty else {
            throw SpotifyLyricsProviderError.missingSpDc
        }

        let bearerToken = try await SpotifyBearerTokenCache.shared.validToken(spDc: cookie, session: session)
        var components = URLComponents(string: "https://spclient.wg.spotify.com/color-lyrics/v2/track/\(trackId)")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "market", value: "from_token"),
        ]
        guard let url = components.url else {
            throw SpotifyLyricsProviderError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = Tuning.lyricsRequestTimeoutSeconds
        SpotifyWebHeaders.apply(
            to: &urlRequest,
            authorization: "Bearer \(bearerToken.accessToken)",
            cookie: "sp_dc=\(cookie)"
        )

        let (data, response) = try await session.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        print("[RokidLyricsSpotifyLyrics] direct lyrics_http_status=\(status) content_type=\(contentType.ifBlank("unknown"))")
        guard (200..<300).contains(status) else {
            throw SpotifyLyricsProviderError.httpStatus(status)
        }
        return try SpotifyColorLyricsParser.parse(
            data: data,
            trackId: trackId,
            request: request,
            provider: providerName,
            sourceLabel: "Spotify color-lyrics"
        )
    }

    private func backendURL(baseURL: String, trackId: String) -> URL? {
        if baseURL.contains("{trackId}") {
            return URL(string: baseURL.replacingOccurrences(of: "{trackId}", with: trackId))
        }
        guard let base = URL(string: baseURL) else { return nil }
        return base.appendingPathComponent(trackId)
    }

    private enum Tuning {
        static let lyricsRequestTimeoutSeconds: TimeInterval = 8
    }
}

enum SpotifyColorLyricsParser {
    static func parse(
        data: Data,
        trackId: String,
        request: LyricsLookupRequest,
        provider: String,
        sourceLabel: String
    ) throws -> LyricsFetchResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpotifyLyricsProviderError.invalidResponse
        }
        return try parse(
            root: root,
            trackId: trackId,
            request: request,
            provider: provider,
            sourceLabel: sourceLabel
        )
    }

    static func parse(
        root: [String: Any],
        trackId: String,
        request: LyricsLookupRequest,
        provider: String,
        sourceLabel: String
    ) throws -> LyricsFetchResult {
        let lyrics = (root["lyrics"] as? [String: Any]) ?? root
        let syncType = (lyrics["syncType"] as? String)
            ?? (root["syncType"] as? String)
            ?? "UNKNOWN"
        let rawLines = (lyrics["lines"] as? [[String: Any]])
            ?? (root["lines"] as? [[String: Any]])
            ?? []
        let lines = rawLines.compactMap(parseLine).sorted { $0.startTimeMs < $1.startTimeMs }
        print("[RokidLyricsSpotifyLyrics] sync_type=\(syncType) line_count=\(lines.count)")

        guard syncType == "LINE_SYNCED", !lines.isEmpty else {
            throw SpotifyLyricsProviderError.noLineSyncedLyrics(syncType: syncType, lineCount: lines.count)
        }

        let trackTitle = root.string("trackTitle")
            .ifBlank(root.string("title"))
            .ifBlank(request.title)
            .ifBlank("Spotify track \(trackId)")
        let artistName = root.string("artistName")
            .ifBlank(root.string("artist"))
            .ifBlank(request.artist)
        let albumName = root.string("albumName")
            .ifBlank(root.string("album"))
            .ifBlank(request.album)
        let durationSeconds = root.int("durationSeconds") ?? request.durationSeconds

        return LyricsFetchResult(
            trackTitle: trackTitle,
            artistName: artistName,
            albumName: albumName,
            durationSeconds: durationSeconds,
            provider: provider,
            synced: true,
            lines: lines,
            plainLyrics: "",
            sourceSummary: "\(sourceLabel) returned LINE_SYNCED lyrics with \(lines.count) timed lines."
        )
    }

    private static func parseLine(_ raw: [String: Any]) -> LyricsLine? {
        guard let startTimeMs = raw.int64("startTimeMs") else { return nil }
        let text = raw.string("words")
            .ifBlank(raw.string("text"))
            .cleanLyricText()
        return LyricsLine(
            startTimeMs: startTimeMs,
            endTimeMs: raw.int64("endTimeMs"),
            text: text.isEmpty ? "(instrumental)" : text
        )
    }
}

private actor SpotifyBearerTokenCache {
    static let shared = SpotifyBearerTokenCache()

    private var token: SpotifyBearerToken?

    func validToken(spDc: String, session: URLSession) async throws -> SpotifyBearerToken {
        let fingerprint = Self.fingerprint(spDc)
        if let token,
           token.cookieFingerprint == fingerprint,
           token.expiresAt > Date().addingTimeInterval(30) {
            return token
        }
        let refreshed = try await fetchToken(spDc: spDc, fingerprint: fingerprint, session: session)
        token = refreshed
        return refreshed
    }

    private func fetchToken(spDc: String, fingerprint: String, session: URLSession) async throws -> SpotifyBearerToken {
        var components = URLComponents(string: "https://open.spotify.com/api/token")!
        components.queryItems = try await SpotifyWebTokenTotp.shared.tokenQueryItems(session: session)
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 8
        SpotifyWebHeaders.apply(to: &request, cookie: "sp_dc=\(spDc)")

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard (200..<300).contains(status),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json.string("accessToken")
                .ifBlank(json.string("access_token"))
                .takeUnlessBlank()
        else {
            print("[RokidLyricsSpotifyLyrics] token_http_status=\(status) content_type=\(contentType.ifBlank("unknown")) is_anonymous=unknown auth_token_len=0")
            throw SpotifyLyricsProviderError.httpStatus(status)
        }
        let isAnonymous = json.truthy("isAnonymous")
        if isAnonymous {
            print("[RokidLyricsSpotifyLyrics] token_http_status=\(status) content_type=\(contentType.ifBlank("unknown")) is_anonymous=true auth_token_len=\(accessToken.count)")
            throw SpotifyLyricsProviderError.anonymousToken
        }

        let expiresAt: Date
        if let expirationMs = json.int64("accessTokenExpirationTimestampMs") {
            expiresAt = Date(timeIntervalSince1970: TimeInterval(expirationMs) / 1000)
        } else if let expiresIn = json.int("expires_in") {
            expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        } else {
            expiresAt = Date().addingTimeInterval(50 * 60)
        }
        print("[RokidLyricsSpotifyLyrics] token_http_status=\(status) content_type=\(contentType.ifBlank("unknown")) is_anonymous=false auth_token_len=\(accessToken.count)")
        return SpotifyBearerToken(
            accessToken: accessToken,
            expiresAt: expiresAt,
            cookieFingerprint: fingerprint
        )
    }

    private static func fingerprint(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
    }
}

private struct SpotifyBearerToken {
    var accessToken: String
    var expiresAt: Date
    var cookieFingerprint: String
}

private enum SpotifyWebHeaders {
    static func apply(to request: inout URLRequest, authorization: String? = nil, cookie: String? = nil) {
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        if let cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
    }

    private static let headers = [
        "Accept": "application/json",
        "Accept-Language": "en-US",
        "Content-Type": "application/json",
        "Origin": "https://open.spotify.com/",
        "Priority": "u=1, i",
        "Referer": "https://open.spotify.com/",
        "Sec-CH-UA": #""Not)A;Brand";v="99", "Google Chrome";v="127", "Chromium";v="127""#,
        "Sec-CH-UA-Mobile": "?0",
        "Sec-CH-UA-Platform": #""Windows""#,
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-site",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36",
        "Spotify-App-Version": "1.2.46.25.g7f189073",
        "App-Platform": "WebPlayer",
    ]
}

private actor SpotifyWebTokenTotp {
    static let shared = SpotifyWebTokenTotp()

    private var cachedSecret: SpotifyTotpSecret?

    func tokenQueryItems(session: URLSession) async throws -> [URLQueryItem] {
        async let secret = validSecret(session: session)
        async let serverTimeMs = fetchServerTimeMs(session: session)
        let resolvedSecret = try await secret
        let resolvedServerTimeMs = try await serverTimeMs
        let totp = Self.generate(timestampMs: resolvedServerTimeMs, secret: resolvedSecret.secret)
        return [
            URLQueryItem(name: "reason", value: "init"),
            URLQueryItem(name: "productType", value: "web-player"),
            URLQueryItem(name: "totp", value: totp),
            URLQueryItem(name: "totpVer", value: resolvedSecret.version),
            URLQueryItem(name: "ts", value: String(resolvedServerTimeMs)),
        ]
    }

    private func validSecret(session: URLSession) async throws -> SpotifyTotpSecret {
        if let cachedSecret { return cachedSecret }
        var request = URLRequest(url: URL(string: "https://raw.githubusercontent.com/xyloflake/spot-secrets-go/main/secrets/secretDict.json")!)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root.keys.compactMap(Int.init).max().map(String.init),
              let asciiCodes = root[version] as? [Any]
        else {
            throw SpotifyLyricsProviderError.httpStatus(status)
        }
        let transformed = asciiCodes.enumerated().compactMap { index, value -> Int? in
            let number: Int?
            if let value = value as? Int {
                number = value
            } else if let value = value as? NSNumber {
                number = value.intValue
            } else {
                number = nil
            }
            return number.map { $0 ^ ((index % 33) + 9) }
        }
        guard transformed.count == asciiCodes.count else {
            throw SpotifyLyricsProviderError.invalidResponse
        }
        let secretString = transformed.map(String.init).joined()
        let secret = SpotifyTotpSecret(secret: Data(secretString.utf8), version: version)
        cachedSecret = secret
        return secret
    }

    private func fetchServerTimeMs(session: URLSession) async throws -> Int64 {
        var request = URLRequest(url: URL(string: "https://open.spotify.com/api/server-time")!)
        request.timeoutInterval = 8
        SpotifyWebHeaders.apply(to: &request)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serverTimeSeconds = root.double("serverTime")
        else {
            throw SpotifyLyricsProviderError.httpStatus(status)
        }
        return Int64(serverTimeSeconds * 1_000)
    }

    private static func generate(timestampMs: Int64, secret: Data) -> String {
        let counterValue = UInt64(timestampMs / 1_000 / 30)
        var counter = counterValue.bigEndian
        let counterData = withUnsafeBytes(of: &counter) { Data($0) }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        secret.withUnsafeBytes { secretBuffer in
            counterData.withUnsafeBytes { counterBuffer in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    secretBuffer.baseAddress,
                    secretBuffer.count,
                    counterBuffer.baseAddress,
                    counterBuffer.count,
                    &digest
                )
            }
        }
        let offset = Int(digest.last ?? 0) & 0x0F
        let binary =
            ((UInt32(digest[offset]) & 0x7F) << 24) |
            ((UInt32(digest[offset + 1]) & 0xFF) << 16) |
            ((UInt32(digest[offset + 2]) & 0xFF) << 8) |
            (UInt32(digest[offset + 3]) & 0xFF)
        return String(format: "%06u", binary % 1_000_000)
    }
}

private struct SpotifyTotpSecret {
    var secret: Data
    var version: String
}
