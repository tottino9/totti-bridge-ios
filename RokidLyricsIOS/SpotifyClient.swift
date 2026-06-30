import CryptoKit
import Foundation
import Security
import UIKit

enum SpotifyAuthStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var label: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .error(let message):
            return message
        }
    }
}

enum SpotifyClientError: LocalizedError {
    case missingClientId
    case missingCallbackCode
    case invalidCallbackState
    case tokenExchangeFailed(String)
    case noActivePlayback
    case userNotAllowlisted
    case rateLimited(String)
    case unsupportedItem
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .missingClientId:
            return "Enter a Spotify Client ID first."
        case .missingCallbackCode:
            return "Spotify did not return an authorization code."
        case .invalidCallbackState:
            return "Spotify login state did not match this device."
        case .tokenExchangeFailed(let message):
            return "Spotify token exchange failed: \(message)"
        case .noActivePlayback:
            return "No active Spotify playback."
        case .userNotAllowlisted:
            return "Spotify rejected this account. Add it to the app allowlist in Developer Mode."
        case .rateLimited(let wait):
            return "Spotify rate limit hit. Retry after \(wait)."
        case .unsupportedItem:
            return "Spotify is playing an episode or unsupported item."
        case .requestTimedOut:
            return "Spotify request timed out."
        }
    }
}

struct SpotifyPlayback: Equatable {
    var snapshot: MediaPlaybackSnapshot
    var observedAt: Date

    var livePositionMs: Int64 {
        guard snapshot.isPlaying else { return snapshot.positionMs }
        let elapsed = Int64(Date().timeIntervalSince(observedAt) * 1000)
        let duration = Int64(snapshot.durationSeconds ?? 0) * 1000
        let next = snapshot.positionMs + max(0, elapsed)
        return duration > 0 ? min(next, duration) : next
    }

    var liveSnapshot: MediaPlaybackSnapshot {
        var next = snapshot
        next.positionMs = livePositionMs
        return next
    }
}

@MainActor
final class SpotifyClient: ObservableObject {
    @Published var clientId: String {
        didSet { defaults.set(clientId.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.clientId) }
    }
    @Published private(set) var status: SpotifyAuthStatus = .disconnected
    @Published private(set) var lastPlayback: SpotifyPlayback?

    var isConnected: Bool { tokenState?.accessToken.isEmpty == false }
    var callbackScheme: String { "rokidlyrics" }
    var redirectURI: String { "\(callbackScheme)://spotify-callback" }

    private let defaults: UserDefaults
    private let session: URLSession
    private var tokenState: TokenState? {
        didSet {
            if let tokenState {
                defaults.set(try? JSONEncoder().encode(tokenState), forKey: Keys.tokenState)
            } else {
                defaults.removeObject(forKey: Keys.tokenState)
            }
        }
    }

    init(defaults: UserDefaults = .standard, session: URLSession = SpotifyClient.makeDefaultSession()) {
        self.defaults = defaults
        self.session = session
        self.clientId = defaults.string(forKey: Keys.clientId) ?? ""
        if let data = defaults.data(forKey: Keys.tokenState),
           let tokenState = try? JSONDecoder().decode(TokenState.self, from: data) {
            self.tokenState = tokenState
            self.status = .connected
        }
    }

    func connect() {
        let trimmedClientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientId.isEmpty else {
            status = .error(SpotifyClientError.missingClientId.localizedDescription)
            return
        }

        let verifier = Self.randomURLSafeString(length: 64)
        let state = Self.randomURLSafeString(length: 32)
        defaults.set(verifier, forKey: Keys.pendingVerifier)
        defaults.set(state, forKey: Keys.pendingState)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: trimmedClientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "user-read-currently-playing user-read-playback-state"),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "state", value: state)
        ]

        guard let url = components.url else { return }
        status = .connecting
        UIApplication.shared.open(url)
    }

    func disconnect() {
        tokenState = nil
        lastPlayback = nil
        status = .disconnected
    }

    func handleOpenURL(_ url: URL) async {
        guard url.scheme == callbackScheme else { return }
        do {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let code = components?.queryItems?.first { $0.name == "code" }?.value
            let state = components?.queryItems?.first { $0.name == "state" }?.value
            guard let code else { throw SpotifyClientError.missingCallbackCode }
            guard state == defaults.string(forKey: Keys.pendingState) else {
                throw SpotifyClientError.invalidCallbackState
            }
            let verifier = defaults.string(forKey: Keys.pendingVerifier).orEmpty
            let token = try await exchangeCode(code, verifier: verifier)
            defaults.removeObject(forKey: Keys.pendingVerifier)
            defaults.removeObject(forKey: Keys.pendingState)
            tokenState = token
            status = .connected
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func fetchCurrentlyPlaying() async throws -> SpotifyPlayback? {
        let accessToken = try await validAccessToken()
        var components = URLComponents(string: "https://api.spotify.com/v1/me/player")!
        components.queryItems = [URLQueryItem(name: "additional_types", value: "track")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = Tuning.playbackRequestTimeoutSeconds
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await data(for: request, timeoutSeconds: Tuning.playbackRequestTimeoutSeconds)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyClientError.noActivePlayback
        }

        switch http.statusCode {
        case 204:
            lastPlayback = nil
            throw SpotifyClientError.noActivePlayback
        case 401:
            tokenState = nil
            status = .disconnected
            throw SpotifyClientError.tokenExchangeFailed("access token expired")
        case 403:
            throw SpotifyClientError.userNotAllowlisted
        case 429:
            let wait = http.value(forHTTPHeaderField: "Retry-After").orEmpty.ifBlank("a moment")
            throw SpotifyClientError.rateLimited(wait)
        case 200..<300:
            break
        default:
            throw SpotifyClientError.tokenExchangeFailed("HTTP \(http.statusCode)")
        }

        let payload = try JSONDecoder().decode(CurrentlyPlayingResponse.self, from: data)
        guard let item = payload.item, item.type == "track" else {
            throw SpotifyClientError.unsupportedItem
        }

        let artists = item.artists.map(\.name).filter { !$0.isEmpty }.joined(separator: ", ")
        let snapshot = MediaPlaybackSnapshot(
            source: "SPOTIFY",
            trackId: item.id,
            title: item.name,
            artist: artists,
            album: item.album.name,
            durationSeconds: item.durationMs / 1000,
            positionMs: Int64(payload.progressMs ?? 0),
            isPlaying: payload.isPlaying,
            isrc: item.externalIds?.isrc
        )
        let playback = SpotifyPlayback(snapshot: snapshot, observedAt: Date())
        lastPlayback = playback
        status = .connected
        return playback
    }

    private func validAccessToken() async throws -> String {
        guard let tokenState else { throw SpotifyClientError.missingClientId }
        if tokenState.expiresAt > Date().addingTimeInterval(30) {
            return tokenState.accessToken
        }
        let refreshed = try await refreshToken(tokenState.refreshToken)
        self.tokenState = refreshed
        return refreshed.accessToken
    }

    private func exchangeCode(_ code: String, verifier: String) async throws -> TokenState {
        let body = [
            "client_id": clientId.trimmingCharacters(in: .whitespacesAndNewlines),
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ]
        return try await tokenRequest(body: body)
    }

    private func refreshToken(_ refreshToken: String) async throws -> TokenState {
        let body = [
            "client_id": clientId.trimmingCharacters(in: .whitespacesAndNewlines),
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        let refreshed = try await tokenRequest(body: body)
        return TokenState(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken.isEmpty ? refreshToken : refreshed.refreshToken,
            expiresAt: refreshed.expiresAt
        )
    }

    private func tokenRequest(body: [String: String]) async throws -> TokenState {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = Tuning.tokenRequestTimeoutSeconds
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\($0.key.urlFormEncoded)=\($0.value.urlFormEncoded)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await data(for: request, timeoutSeconds: Tuning.tokenRequestTimeoutSeconds)
        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(httpCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpCode)"
            throw SpotifyClientError.tokenExchangeFailed(message)
        }
        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        return TokenState(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expiresIn))
        )
    }

    private func data(for request: URLRequest, timeoutSeconds: TimeInterval) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { [session] in
                try await session.data(for: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw SpotifyClientError.requestTimedOut
            }

            guard let result = try await group.next() else {
                throw SpotifyClientError.requestTimedOut
            }
            group.cancelAll()
            return result
        }
    }

    nonisolated private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = Tuning.playbackRequestTimeoutSeconds
        configuration.timeoutIntervalForResource = Tuning.tokenRequestTimeoutSeconds
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func randomURLSafeString(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            var fallback = ""
            while fallback.count < length {
                fallback += UUID().uuidString.replacingOccurrences(of: "-", with: "")
            }
            return String(fallback.prefix(length))
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}

private enum Tuning {
    static let playbackRequestTimeoutSeconds: TimeInterval = 4
    static let tokenRequestTimeoutSeconds: TimeInterval = 8
}

private struct TokenState: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

private struct TokenResponse: Decodable {
    var accessToken: String
    var tokenType: String
    var expiresIn: Int
    var refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

private struct CurrentlyPlayingResponse: Decodable {
    var timestamp: Int64?
    var progressMs: Int?
    var isPlaying: Bool
    var item: SpotifyTrack?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case progressMs = "progress_ms"
        case isPlaying = "is_playing"
        case item
    }
}

private struct SpotifyTrack: Decodable {
    var id: String
    var name: String
    var type: String
    var durationMs: Int
    var album: SpotifyAlbum
    var artists: [SpotifyArtist]
    var externalIds: SpotifyExternalIds?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case durationMs = "duration_ms"
        case album
        case artists
        case externalIds = "external_ids"
    }
}

private struct SpotifyAlbum: Decodable {
    var name: String
}

private struct SpotifyArtist: Decodable {
    var name: String
}

private struct SpotifyExternalIds: Decodable {
    var isrc: String?
}

private enum Keys {
    static let clientId = "spotify.clientId"
    static let tokenState = "spotify.tokenState"
    static let pendingVerifier = "spotify.pendingVerifier"
    static let pendingState = "spotify.pendingState"
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlFormAllowed) ?? self
    }
}

private extension CharacterSet {
    static let urlFormAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return allowed
    }()
}
