import CommonCrypto
import Foundation

struct MusixmatchCredentials: Equatable {
    var email: String
    var password: String
}

struct MusixmatchLyricsProvider: LyricsProvider {
    let providerName = "MUSIXMATCH"
    var credentials: MusixmatchCredentials?
    var session: URLSession = .shared
    private static let sessionCache = MusixmatchSessionCache()

    func fetch(_ request: LyricsLookupRequest) async -> LyricsProviderAttempt {
        guard let credentials,
              !credentials.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.password.isEmpty else {
            return .disabled(provider: providerName, reason: "Sign in to Musixmatch to enable synced subtitles.")
        }

        do {
            let userToken = try await authenticatedUserToken(credentials: credentials)
            guard let track = try await resolveBestTrack(request, userToken: userToken) else {
                return .noMatch(provider: providerName, reason: "No Musixmatch match with line-synced subtitles for \(request.title) by \(request.artist).")
            }
            guard let subtitle = try await fetchSubtitle(trackId: track.trackId, userToken: userToken) else {
                return .noMatch(provider: providerName, reason: "Musixmatch found the track but did not return line-synced subtitles.")
            }
            let lines = LrcParser.parseSyncedLyrics(subtitle)
            guard !lines.isEmpty else {
                return .noMatch(provider: providerName, reason: "Musixmatch subtitle payload could not be parsed into timed lines.")
            }
            return .success(
                LyricsFetchResult(
                    trackTitle: track.trackName.ifBlank(request.title),
                    artistName: track.artistName.ifBlank(request.artist),
                    albumName: track.albumName.ifBlank(request.album),
                    durationSeconds: track.durationSeconds ?? request.durationSeconds,
                    provider: providerName,
                    synced: true,
                    lines: lines,
                    plainLyrics: "",
                    sourceSummary: "Synced lyrics loaded from Musixmatch with \(lines.count) timed lines."
                )
            )
        } catch {
            return .noMatch(provider: providerName, reason: error.localizedDescription)
        }
    }

    private func authenticatedUserToken(credentials: MusixmatchCredentials) async throws -> String {
        if let cachedToken = try await Self.sessionCache.validUserToken(for: credentials) {
            return cachedToken
        }

        do {
            let userToken = try await fetchUserToken()
            try await login(credentials: credentials, userToken: userToken)
            await Self.sessionCache.save(userToken: userToken, credentials: credentials)
            return userToken
        } catch {
            if MusixmatchError.isCaptchaRelated(error) {
                await Self.sessionCache.noteCaptcha()
            }
            throw error
        }
    }

    private func resolveBestTrack(_ request: LyricsLookupRequest, userToken: String) async throws -> MusixmatchTrack? {
        if let matcher = try await fetchMatcherCandidate(request, userToken: userToken),
           candidateScore(matcher, request: request) != nil {
            return matcher
        }

        var candidates: [MusixmatchTrack] = []
        let queries = [
            "\(request.title.trimmingCharacters(in: .whitespacesAndNewlines)) \(request.artist.trimmingCharacters(in: .whitespacesAndNewlines))",
            request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for query in Array(Set(queries)) {
            candidates.append(contentsOf: try await searchTracks(query: query, userToken: userToken))
        }
        return pickSearchCandidate(candidates, request: request)
    }

    private func fetchMatcherCandidate(_ request: LyricsLookupRequest, userToken: String) async throws -> MusixmatchTrack? {
        let json = try await signedRequest(
            endpoint: "matcher.track.get",
            params: [
                "q_track": request.title,
                "q_artist": request.artist,
                "q_album": request.album,
                "subtitle_format": "dfxp",
                "optional_calls": "track.richsync",
                "part": "lyrics_crowd,user,lyrics_vote,track_lyrics_translation_status,lyrics_verified_by,labels,track_isrc,writer_list,credits"
            ].filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            userToken: userToken
        )
        return (((json["message"] as? [String: Any])?["body"] as? [String: Any])?["track"] as? [String: Any])?
            .toMusixmatchTrack()
    }

    private func searchTracks(query: String, userToken: String) async throws -> [MusixmatchTrack] {
        let json = try await signedRequest(
            endpoint: "macro.search",
            params: [
                "q": query,
                "part": "track_artist,artist_image",
                "track_fields_set": "android_track_list",
                "artist_fields_set": "android_track_list_artist",
                "page": "1",
                "page_size": "5"
            ],
            userToken: userToken
        )
        let body = (json["message"] as? [String: Any])?["body"] as? [String: Any]
        let macro = body?["macro_result_list"] as? [String: Any]
        let list = macro?["track_list"] as? [[String: Any]] ?? []
        return list.compactMap { wrapper in
            ((wrapper["track"] as? [String: Any]) ?? wrapper).toMusixmatchTrack()
        }
    }

    private func fetchSubtitle(trackId: Int64, userToken: String) async throws -> String? {
        let json = try await signedRequest(
            endpoint: "track.subtitle.get",
            params: [
                "track_id": String(trackId),
                "subtitle_format": "lrc"
            ],
            userToken: userToken
        )
        let body = (json["message"] as? [String: Any])?["body"] as? [String: Any]
        let subtitle = body?["subtitle"] as? [String: Any]
        return (subtitle?["subtitle_body"] as? String)?.takeUnlessBlank()
    }

    private func fetchUserToken() async throws -> String {
        let json = try await signedRequest(endpoint: "token.get", params: [:], userToken: nil)
        let body = (json["message"] as? [String: Any])?["body"] as? [String: Any]
        guard let token = (body?["user_token"] as? String)?.takeUnlessBlank() else {
            throw MusixmatchError.message("token.get did not return a user token")
        }
        return token
    }

    private func login(credentials: MusixmatchCredentials, userToken: String) async throws {
        let payload: [String: Any] = [
            "credential_list": [
                [
                    "credential": [
                        "type": "mxm",
                        "action": "login",
                        "email": credentials.email,
                        "password": credentials.password
                    ]
                ]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await signedRequest(
            endpoint: "credential.post",
            params: [:],
            userToken: userToken,
            method: "POST",
            body: body
        )
    }

    private func signedRequest(
        endpoint: String,
        params: [String: String],
        userToken: String?,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> [String: Any] {
        let now = Date()
        var components = URLComponents(string: "\(Self.baseURL)\(endpoint)")!
        var query = [
            URLQueryItem(name: "app_id", value: Self.appId),
            URLQueryItem(name: "usertoken", value: userToken ?? ""),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "signature", value: Self.signature(endpoint: endpoint, date: now)),
            URLQueryItem(name: "signature_protocol", value: "sha1")
        ]
        if endpoint == "token.get" {
            query.append(URLQueryItem(name: "timestamp", value: Self.tokenTimestampFormatter.string(from: now)))
            query.append(URLQueryItem(name: "guid", value: UUID().uuidString.replacingOccurrences(of: "-", with: "")))
        }
        query.append(contentsOf: params.map { URLQueryItem(name: $0.key, value: $0.value) })
        components.queryItems = query

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 4
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
        request.setValue("default", forHTTPHeaderField: "x-mxm-endpoint")
        request.setValue("x-mxm-token-guid=\(UUID().uuidString.replacingOccurrences(of: "-", with: "")); mxm-encrypted-token=; x-mxm-user-id=; AWSELB=unknown", forHTTPHeaderField: "Cookie")
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body ?? Data("{}".utf8)
        }

        let (data, response) = try await session.data(for: request)
        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let header = ((json["message"] as? [String: Any])?["header"] as? [String: Any])
        let statusCode = header?["status_code"] as? Int ?? httpCode
        guard statusCode == 200 else {
            let hint = header?["hint"] as? String
            if statusCode == 401, hint?.localizedCaseInsensitiveContains("captcha") == true {
                throw MusixmatchError.captcha(endpoint: endpoint)
            }
            throw MusixmatchError.message("Musixmatch \(endpoint) failed (\(statusCode)): \(hint ?? "unknown error")")
        }
        return json
    }

    private func pickSearchCandidate(_ candidates: [MusixmatchTrack], request: LyricsLookupRequest) -> MusixmatchTrack? {
        var seen = Set<Int64>()
        return candidates
            .filter { seen.insert($0.trackId).inserted }
            .compactMap { candidate in
                candidateScore(candidate, request: request).map { (candidate, $0) }
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    private func candidateScore(_ candidate: MusixmatchTrack, request: LyricsLookupRequest) -> Int? {
        let titleScore = TextMatch.score(request: request.title, candidate: candidate.trackName)
        let artistScore = TextMatch.score(request: request.artist, candidate: candidate.artistName)
        guard titleScore >= 55, artistScore >= 40 else { return nil }

        var score = titleScore * 3 + artistScore * 2
        if !request.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += TextMatch.score(request: request.album, candidate: candidate.albumName) / 2
        }
        score += candidate.hasSubtitles == true ? 30 : -35
        if let requestDuration = request.durationSeconds, let candidateDuration = candidate.durationSeconds {
            let delta = abs(requestDuration - candidateDuration)
            switch delta {
            case 0...1: score += 25
            case 2...3: score += 15
            case 4...6: score += 5
            case 20...: score -= 40
            default: score -= 10
            }
        }
        if TextMatch.comparable(request.title) == TextMatch.comparable(candidate.trackName) { score += 40 }
        if TextMatch.comparable(request.artist) == TextMatch.comparable(candidate.artistName) { score += 30 }
        return score
    }

    private static func signature(endpoint: String, date: Date) -> String {
        let payload = endpoint + signatureDateFormatter.string(from: date)
        return hmacSHA1(payload, key: signingKey).base64URLEncodedString()
    }

    private static func hmacSHA1(_ value: String, key: String) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        let keyBytes = Array(key.utf8)
        let valueBytes = Array(value.utf8)
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), keyBytes, keyBytes.count, valueBytes, valueBytes.count, &digest)
        return Data(digest)
    }

    fileprivate static func credentialCacheKey(_ credentials: MusixmatchCredentials) -> String {
        let normalizedEmail = credentials.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sha256Hex("\(normalizedEmail)\u{0}\(credentials.password)")
    }

    private static func sha256Hex(_ value: String) -> String {
        let data = Data(value.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let baseURL = "https://apic.musixmatch.com/ws/1.1/"
    private static let appId = "android-player-v1.0"
    private static let signingKey = "IEJ5E8XFaHQvIQNfs7IC"
    private static let userAgent = "Dalvik/2.1.0 (Linux; U; Android 16; Pixel 8 Pro Build/BP31.250502.008)"

    private static let signatureDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private static let tokenTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()
}

private actor MusixmatchSessionCache {
    private var cachedSession: MusixmatchSession?
    private var captchaCooldownUntil: Date?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let userToken = defaults.string(forKey: Keys.userToken),
           let credentialKey = defaults.string(forKey: Keys.credentialKey),
           let expiresAt = defaults.object(forKey: Keys.expiresAt) as? Date {
            cachedSession = MusixmatchSession(
                credentialKey: credentialKey,
                userToken: userToken,
                expiresAt: expiresAt
            )
        }
    }

    func validUserToken(for credentials: MusixmatchCredentials) throws -> String? {
        if let captchaCooldownUntil, captchaCooldownUntil > Date() {
            throw MusixmatchError.captchaCooldown
        }

        guard let cachedSession,
              cachedSession.credentialKey == MusixmatchLyricsProvider.credentialCacheKey(credentials),
              cachedSession.expiresAt > Date().addingTimeInterval(Self.expirySafetySeconds)
        else {
            return nil
        }

        return cachedSession.userToken
    }

    func save(userToken: String, credentials: MusixmatchCredentials) {
        let session = MusixmatchSession(
            credentialKey: MusixmatchLyricsProvider.credentialCacheKey(credentials),
            userToken: userToken,
            expiresAt: Date().addingTimeInterval(Self.tokenExpirySeconds)
        )
        cachedSession = session
        defaults.set(session.credentialKey, forKey: Keys.credentialKey)
        defaults.set(session.userToken, forKey: Keys.userToken)
        defaults.set(session.expiresAt, forKey: Keys.expiresAt)
    }

    func noteCaptcha() {
        captchaCooldownUntil = Date().addingTimeInterval(Self.captchaCooldownSeconds)
        clearSession()
    }

    private func clearSession() {
        cachedSession = nil
        defaults.removeObject(forKey: Keys.credentialKey)
        defaults.removeObject(forKey: Keys.userToken)
        defaults.removeObject(forKey: Keys.expiresAt)
    }

    private enum Keys {
        static let credentialKey = "musixmatch.session.credentialKey"
        static let userToken = "musixmatch.session.userToken"
        static let expiresAt = "musixmatch.session.expiresAt"
    }

    private static let tokenExpirySeconds: TimeInterval = 10 * 60
    private static let expirySafetySeconds: TimeInterval = 30
    private static let captchaCooldownSeconds: TimeInterval = 5 * 60
}

private struct MusixmatchSession: Equatable {
    var credentialKey: String
    var userToken: String
    var expiresAt: Date
}

private struct MusixmatchTrack: Equatable {
    var trackId: Int64
    var trackName: String
    var artistName: String
    var albumName: String
    var durationSeconds: Int?
    var hasSubtitles: Bool?
}

private enum MusixmatchError: LocalizedError {
    case message(String)
    case captcha(endpoint: String)
    case captchaCooldown

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        case .captcha(let endpoint):
            return "Musixmatch \(endpoint) failed (401): captcha"
        case .captchaCooldown:
            return "Musixmatch captcha cooldown active; retrying later."
        }
    }

    var isCaptchaRelated: Bool {
        switch self {
        case .captcha, .captchaCooldown:
            return true
        case .message:
            return false
        }
    }

    static func isCaptchaRelated(_ error: Error) -> Bool {
        (error as? MusixmatchError)?.isCaptchaRelated == true
    }
}

private extension Dictionary where Key == String, Value == Any {
    func toMusixmatchTrack() -> MusixmatchTrack? {
        let id = int64("track_id") ?? int("track_id").map(Int64.init)
        guard let id else { return nil }
        let hasSubtitles: Bool?
        if let raw = int("has_subtitles") {
            hasSubtitles = raw != 0
        } else {
            hasSubtitles = nil
        }
        return MusixmatchTrack(
            trackId: id,
            trackName: string("track_name"),
            artistName: string("artist_name"),
            albumName: string("album_name"),
            durationSeconds: int("track_length"),
            hasSubtitles: hasSubtitles
        )
    }
}
