import Foundation

enum LyricsClientError: LocalizedError, Equatable {
    case missingRequiredFields
    case noLyricsFound
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingRequiredFields:
            return "Track title and artist are required."
        case .noLyricsFound:
            return "No lyrics found on LRCLIB for this track."
        case .invalidResponse:
            return "LRCLIB returned an invalid response."
        }
    }
}

struct LrcLibLyricsClient: LyricsProvider {
    let providerName = "LRCLIB"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(_ request: LyricsLookupRequest) async -> LyricsProviderAttempt {
        do {
            return .success(try await fetchResult(request))
        } catch LyricsClientError.noLyricsFound {
            return .noMatch(provider: providerName, reason: "No synced lyrics found on LRCLIB for \(request.title) by \(request.artist).")
        } catch LyricsClientError.missingRequiredFields {
            return .noMatch(provider: providerName, reason: "LRCLIB lookup requires title and artist.")
        } catch {
            return .noMatch(provider: providerName, reason: error.localizedDescription)
        }
    }

    func fetchResult(_ request: LyricsLookupRequest) async throws -> LyricsFetchResult {
        let normalized = LyricsLookupRequest(
            title: request.title.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: request.artist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: request.album.trimmingCharacters(in: .whitespacesAndNewlines),
            durationSeconds: request.durationSeconds,
            isrc: request.isrc
        )

        guard !normalized.title.isEmpty, !normalized.artist.isEmpty else {
            throw LyricsClientError.missingRequiredFields
        }

        if let cached = try await fetchTrack(path: "/api/get-cached", request: normalized) {
            return parse(track: cached, request: normalized)
        }

        if let exact = try await fetchTrack(path: "/api/get", request: normalized) {
            return parse(track: exact, request: normalized)
        }

        if let search = try await fetchSearchFallback(request: normalized) {
            return parse(track: search, request: normalized)
        }

        throw LyricsClientError.noLyricsFound
    }

    private func fetchTrack(path: String, request: LyricsLookupRequest) async throws -> LrcLibTrack? {
        guard let url = url(path: path, request: request) else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("Rokid-Lyrics-iOS/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LyricsClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode), !data.isEmpty else {
            return nil
        }
        return try JSONDecoder().decode(LrcLibTrack.self, from: data)
    }

    private func fetchSearchFallback(request: LyricsLookupRequest) async throws -> LrcLibTrack? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: request.title),
            URLQueryItem(name: "artist_name", value: request.artist)
        ]
        if !request.album.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "album_name", value: request.album))
        }
        guard let url = components?.url else { return nil }

        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("Rokid-Lyrics-iOS/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LyricsClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode), !data.isEmpty else {
            return nil
        }

        let candidates = try JSONDecoder().decode([LrcLibTrack].self, from: data)
        return pickSearchCandidate(candidates, request: request)
    }

    private func pickSearchCandidate(_ candidates: [LrcLibTrack], request: LyricsLookupRequest) -> LrcLibTrack? {
        candidates
            .compactMap { candidate -> (LrcLibTrack, Int)? in
                guard let score = score(candidate: candidate, request: request) else { return nil }
                return (candidate, score)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    private func score(candidate: LrcLibTrack, request: LyricsLookupRequest) -> Int? {
        let titleScore = TextMatch.score(request: request.title, candidate: candidate.trackName)
        let artistScore = TextMatch.score(request: request.artist, candidate: candidate.artistName)
        guard titleScore >= 55, artistScore >= 40 else { return nil }

        var score = titleScore * 3 + artistScore * 2
        if !request.album.isEmpty {
            score += TextMatch.score(request: request.album, candidate: candidate.albumName ?? "") / 2
        }

        if let syncedLyrics = candidate.syncedLyrics, !syncedLyrics.isEmpty {
            score += 35
        } else if let plainLyrics = candidate.plainLyrics, !plainLyrics.isEmpty {
            score += 10
        } else {
            score -= 25
        }

        if let requestedDuration = request.durationSeconds, let candidateDuration = candidate.duration {
            let delta = abs(requestedDuration - candidateDuration)
            switch delta {
            case 0...1:
                score += 25
            case 2...3:
                score += 15
            case 4...6:
                score += 5
            case 20...:
                score -= 40
            default:
                score -= 10
            }
        }

        if TextMatch.comparable(request.title) == TextMatch.comparable(candidate.trackName) {
            score += 40
        }
        if TextMatch.comparable(request.artist) == TextMatch.comparable(candidate.artistName) {
            score += 30
        }

        return score
    }

    private func parse(track: LrcLibTrack, request: LyricsLookupRequest) -> LyricsFetchResult {
        let syncedLyrics = track.syncedLyrics ?? ""
        let plainLyrics = track.plainLyrics ?? ""
        let lines = LrcParser.parseSyncedLyrics(syncedLyrics)
        let synced = !lines.isEmpty
        let summary: String

        if track.instrumental == true {
            summary = "Instrumental track reported by LRCLIB."
        } else if synced {
            summary = "Synced lyrics loaded from LRCLIB with \(lines.count) timed lines."
        } else if !plainLyrics.isEmpty {
            summary = "Plain lyrics loaded from LRCLIB."
        } else {
            summary = "Track resolved on LRCLIB, but no lyrics payload was returned."
        }

        return LyricsFetchResult(
            trackTitle: track.trackName.isEmpty ? request.title : track.trackName,
            artistName: track.artistName.isEmpty ? request.artist : track.artistName,
            albumName: track.albumName ?? request.album,
            durationSeconds: track.duration ?? request.durationSeconds,
            provider: "LRCLIB",
            synced: synced,
            lines: lines,
            plainLyrics: plainLyrics,
            sourceSummary: summary
        )
    }

    private func url(path: String, request: LyricsLookupRequest) -> URL? {
        var components = URLComponents(string: "https://lrclib.net\(path)")
        var items = [
            URLQueryItem(name: "track_name", value: request.title),
            URLQueryItem(name: "artist_name", value: request.artist)
        ]
        if !request.album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: request.album))
        }
        if let duration = request.durationSeconds, duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        components?.queryItems = items
        return components?.url
    }
}

private struct LrcLibTrack: Decodable {
    var trackName: String
    var artistName: String
    var albumName: String?
    var duration: Int?
    var syncedLyrics: String?
    var plainLyrics: String?
    var instrumental: Bool?
}
