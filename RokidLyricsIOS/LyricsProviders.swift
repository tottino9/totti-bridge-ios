import Foundation

enum LyricsProviderAttempt: Equatable {
    case success(LyricsFetchResult)
    case noMatch(provider: String, reason: String)
    case disabled(provider: String, reason: String)
}

protocol LyricsProvider {
    var providerName: String { get }
    func fetch(_ request: LyricsLookupRequest) async -> LyricsProviderAttempt
}

struct ProviderAttemptSummary: Equatable {
    var provider: String
    var outcome: Outcome
    var detail: String

    enum Outcome: String, Equatable {
        case success
        case noMatch
        case disabled
        case error
    }
}

struct CompositeLyricsFetchResult: Equatable {
    var result: LyricsFetchResult
    var attemptSummaries: [ProviderAttemptSummary]
}

struct CompositeLyricsProvider {
    var providers: [LyricsProvider]

    func fetch(_ request: LyricsLookupRequest) async -> CompositeLyricsFetchResult {
        var disabledProviders: [String] = []
        var attemptDetails: [String] = []
        var summaries: [ProviderAttemptSummary] = []

        for provider in providers {
            let attempt = await provider.fetch(request)
            switch attempt {
            case .success(let result):
                summaries.append(.init(provider: result.provider, outcome: .success, detail: result.sourceSummary))
                let sourceSummary = attemptDetails.isEmpty
                    ? result.sourceSummary
                    : "\(result.sourceSummary) Fallback context: \(attemptDetails.joined(separator: " | "))"
                var next = result
                next.sourceSummary = sourceSummary
                return CompositeLyricsFetchResult(result: next, attemptSummaries: summaries)

            case .noMatch(let provider, let reason):
                summaries.append(.init(provider: provider, outcome: .noMatch, detail: reason))
                attemptDetails.append("\(provider): \(reason)")

            case .disabled(let provider, let reason):
                summaries.append(.init(provider: provider, outcome: .disabled, detail: reason))
                disabledProviders.append(provider)
                attemptDetails.append("\(provider): \(reason)")
            }
        }

        let providerNames = providers.map { $0.providerName }
        let activeProviders = providerNames.filter { !disabledProviders.contains($0) }
        let providerSummary = (activeProviders.isEmpty ? providerNames : activeProviders).joined(separator: "+")
        let sourceSummary: String
        if disabledProviders.count == providers.count {
            sourceSummary = "No synced lyrics provider is configured yet. \(attemptDetails.joined(separator: " | "))"
        } else if !attemptDetails.isEmpty {
            sourceSummary = "No synced lyrics found on \(providerSummary). \(attemptDetails.joined(separator: " | "))"
        } else {
            sourceSummary = "No synced lyrics found on \(providerSummary)."
        }

        return CompositeLyricsFetchResult(
            result: LyricsFetchResult(
                trackTitle: request.title,
                artistName: request.artist,
                albumName: request.album,
                durationSeconds: request.durationSeconds,
                provider: providerSummary,
                synced: false,
                lines: [],
                plainLyrics: "",
                sourceSummary: sourceSummary
            ),
            attemptSummaries: summaries
        )
    }
}
