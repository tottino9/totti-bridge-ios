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

private enum ProviderRaceOutcome {
    case attempt(LyricsProviderAttempt, elapsedMs: Int)
    case deadline
}

struct CompositeLyricsProvider {
    var providers: [LyricsProvider]

    /// Total wall-clock budget for a single lookup. Providers run concurrently and the
    /// first success wins, so this only bounds the worst case where every provider is
    /// slow — replacing the old serial chain whose worst case was ~50s.
    static let overallDeadlineSeconds: Double = 9

    func fetch(_ request: LyricsLookupRequest) async -> CompositeLyricsFetchResult {
        let providers = self.providers
        guard !providers.isEmpty else {
            return Self.failureResult(request: request, providers: providers, summaries: [], attemptDetails: [], disabledProviders: [])
        }

        return await withTaskGroup(of: ProviderRaceOutcome.self) { group in
            for provider in providers {
                group.addTask {
                    let startedAt = Date()
                    print("[RokidLyricsLookup] provider=\(provider.providerName) start title=\"\(request.title)\" artist=\"\(request.artist)\"")
                    let attempt = await provider.fetch(request)
                    let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                    return .attempt(attempt, elapsedMs: elapsedMs)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.overallDeadlineSeconds * 1_000_000_000))
                return .deadline
            }

            var summaries: [ProviderAttemptSummary] = []
            var attemptDetails: [String] = []
            var disabledProviders: [String] = []
            var finished = 0

            for await outcome in group {
                switch outcome {
                case .deadline:
                    print("[RokidLyricsLookup] deadline reached after \(Self.overallDeadlineSeconds)s; returning best-effort")
                    group.cancelAll()
                    return Self.failureResult(request: request, providers: providers, summaries: summaries, attemptDetails: attemptDetails, disabledProviders: disabledProviders)

                case let .attempt(attempt, elapsedMs):
                    finished += 1
                    switch attempt {
                    case .success(let result):
                        print("[RokidLyricsLookup] provider=\(result.provider) success elapsedMs=\(elapsedMs) synced=\(result.synced) lines=\(result.lines.count)")
                        summaries.append(.init(provider: result.provider, outcome: .success, detail: result.sourceSummary))
                        group.cancelAll()
                        var next = result
                        if !attemptDetails.isEmpty {
                            next.sourceSummary = "\(result.sourceSummary) Fallback context: \(attemptDetails.joined(separator: " | "))"
                        }
                        return CompositeLyricsFetchResult(result: next, attemptSummaries: summaries)

                    case .noMatch(let provider, let reason):
                        print("[RokidLyricsLookup] provider=\(provider) noMatch elapsedMs=\(elapsedMs) reason=\"\(reason)\"")
                        summaries.append(.init(provider: provider, outcome: .noMatch, detail: reason))
                        attemptDetails.append("\(provider): \(reason)")

                    case .disabled(let provider, let reason):
                        print("[RokidLyricsLookup] provider=\(provider) disabled elapsedMs=\(elapsedMs) reason=\"\(reason)\"")
                        summaries.append(.init(provider: provider, outcome: .disabled, detail: reason))
                        disabledProviders.append(provider)
                        attemptDetails.append("\(provider): \(reason)")
                    }

                    // Every real provider has reported and none succeeded.
                    if finished >= providers.count {
                        group.cancelAll()
                        return Self.failureResult(request: request, providers: providers, summaries: summaries, attemptDetails: attemptDetails, disabledProviders: disabledProviders)
                    }
                }
            }

            return Self.failureResult(request: request, providers: providers, summaries: summaries, attemptDetails: attemptDetails, disabledProviders: disabledProviders)
        }
    }

    private static func failureResult(
        request: LyricsLookupRequest,
        providers: [LyricsProvider],
        summaries: [ProviderAttemptSummary],
        attemptDetails: [String],
        disabledProviders: [String]
    ) -> CompositeLyricsFetchResult {
        let providerNames = providers.map { $0.providerName }
        let activeProviders = providerNames.filter { !disabledProviders.contains($0) }
        let providerSummary = (activeProviders.isEmpty ? providerNames : activeProviders).joined(separator: "+")
        let sourceSummary: String
        if !providers.isEmpty, disabledProviders.count == providers.count {
            sourceSummary = "No synced lyrics provider is configured yet. \(attemptDetails.joined(separator: " | "))"
        } else if !attemptDetails.isEmpty {
            sourceSummary = "No synced lyrics found on \(providerSummary). \(attemptDetails.joined(separator: " | "))"
        } else {
            sourceSummary = providerSummary.isEmpty
                ? "No synced lyrics provider is configured yet."
                : "No synced lyrics found on \(providerSummary)."
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
