import Foundation

struct SpotifyLyricsService {
    var provider: SpotifyLyricsProvider

    func fetch(trackInput: String) async -> LyricsProviderAttempt {
        await provider.fetchTrackInput(trackInput)
    }

    func fetch(request: LyricsLookupRequest) async -> LyricsProviderAttempt {
        await provider.fetch(request)
    }
}
