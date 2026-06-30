import AVFoundation
import Combine
import Compression
import Foundation
import UIKit

struct LyricDisplayLine: Identifiable, Equatable {
    var id: Int
    var text: String
    var role: Role

    enum Role: Equatable {
        case previous
        case current
        case next
        case empty
    }
}

enum LyricsRuntimeDeepLink: Equatable {
    case sample
    case lookup(LookupPayload)
    case spotifyLyrics(SpotifyLyricsPayload)

    struct LookupPayload: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: String
        var autoplay: Bool
        var progressMs: Int64
    }

    struct SpotifyLyricsPayload: Equatable {
        var input: String
        var mode: SpotifyLyricsSourceMode?
    }

    init?(url: URL) {
        guard url.scheme == "rokidlyrics",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value
        }

        switch url.host {
        case "sample":
            self = .sample

        case "lookup":
            guard let title = values["title"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let artist = values["artist"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  !artist.isEmpty
            else { return nil }
            self = .lookup(
                LookupPayload(
                    title: title,
                    artist: artist,
                    album: values["album"] ?? "",
                    duration: values["duration"] ?? "",
                    autoplay: Self.isTruthy(values["autoplay"]) || Self.isTruthy(values["play"]),
                    progressMs: Int64(values["progressMs"] ?? values["positionMs"] ?? "0") ?? 0
                )
            )

        case "spotify-lyrics":
            let input = (values["trackId"] ?? "")
                .ifBlank(values["id"] ?? "")
                .ifBlank(values["url"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard SpotifyTrackIdentifier.extract(from: input) != nil else { return nil }
            self = .spotifyLyrics(
                SpotifyLyricsPayload(
                    input: input,
                    mode: values["mode"].flatMap(SpotifyLyricsSourceMode.init(rawValue:))
                )
            )

        default:
            return nil
        }
    }

    private static func isTruthy(_ value: String?) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}

enum PlainLyricsTiming {
    static func estimatedLines(from plainLyrics: String, durationSeconds: Int?) -> [LyricsLine] {
        let textLines = plainLyrics
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard textLines.count > 1 else { return [] }

        let durationMs: Int64
        if let durationSeconds, durationSeconds > 0 {
            durationMs = Int64(durationSeconds) * 1000
        } else {
            durationMs = Int64(textLines.count) * Tuning.fallbackLineDurationMs
        }
        let intervalMs = max(Tuning.minimumLineDurationMs, durationMs / Int64(textLines.count))

        return textLines.enumerated().map { index, text in
            LyricsLine(startTimeMs: Int64(index) * intervalMs, text: text)
        }
    }

    private enum Tuning {
        static let minimumLineDurationMs: Int64 = 2_500
        static let fallbackLineDurationMs: Int64 = 4_000
    }
}

enum LyricsTransportWindow {
    static func lineRange(
        lineCount: Int,
        anchorIndex: Int,
        maxLines: Int,
        previousLines: Int
    ) -> (range: Range<Int>, relativeCurrentLineIndex: Int) {
        guard lineCount > 0, maxLines > 0 else {
            return (0..<0, -1)
        }

        let boundedAnchor = min(max(anchorIndex, 0), lineCount - 1)
        let refreshStride = max(1, maxLines / 2)
        let bucketAnchor = (boundedAnchor / refreshStride) * refreshStride
        let maxStartIndex = max(0, lineCount - maxLines)
        let startIndex = min(maxStartIndex, max(0, bucketAnchor - max(previousLines, 0)))
        let endIndex = min(lineCount, startIndex + maxLines)
        return (startIndex..<endIndex, boundedAnchor - startIndex)
    }
}

struct LyricsTransportWindowToken: Equatable {
    var mediaKey: String
    var revision: Int64
    var range: Range<Int>
}

@MainActor
final class LyricsRuntimeStore: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var durationSecondsText = ""
    @Published var spotifyClientId: String {
        didSet { spotifyClient.clientId = spotifyClientId }
    }

    @Published var spotifyLyricsInput: String {
        didSet { defaults.set(spotifyLyricsInput, forKey: Keys.spotifyLyricsInput) }
    }

    @Published var spotifyLyricsMode: SpotifyLyricsSourceMode {
        didSet { defaults.set(spotifyLyricsMode.rawValue, forKey: Keys.spotifyLyricsMode) }
    }

    @Published var spotifyLyricsBackendURL: String {
        didSet { defaults.set(spotifyLyricsBackendURL, forKey: Keys.spotifyLyricsBackendURL) }
    }

    @Published var spotifySpDc: String {
        didSet { persistSpotifySpDc() }
    }

    @Published var spotifyMonitoringEnabled = true {
        didSet {
            if spotifyMonitoringEnabled {
                suppressSpotifyPollingUntil = nil
                scheduleSpotifyPoll(force: true)
            } else {
                stopBackgroundSpotifyPolling()
            }
        }
    }
    @Published var musixmatchEmail: String {
        didSet { defaults.set(musixmatchEmail, forKey: Keys.musixmatchEmail) }
    }

    @Published var musixmatchPassword: String {
        didSet { defaults.set(musixmatchPassword, forKey: Keys.musixmatchPassword) }
    }

    @Published private(set) var snapshot = LyricsSnapshot()
    @Published private(set) var deviceStatus = DeviceStatus(connectionState: .connecting, statusLabel: "iOS runtime ready.")
    @Published private(set) var isLookingUp = false
    @Published private(set) var isPlaying = false
    @Published private(set) var statusLabel = "Enter a track or connect Spotify."
    @Published private(set) var spotifyAuthStatus: SpotifyAuthStatus = .disconnected
    @Published private(set) var spotifyNowPlayingLabel = "Spotify idle."
    @Published private(set) var providerStatusLabel = "Providers: Spotify for track IDs; LRCLIB, Netease, Musixmatch fallback."

    private let defaults: UserDefaults
    private let keychain: KeychainSecretStore
    private let spotifyClient: SpotifyClient
    private let glassesTransport: LyricsGlassesTransport
    private var cancellables = Set<AnyCancellable>()
    private var runtimeTicker: AnyCancellable?
    private var playbackSource: PlaybackSource = .manual
    private var playbackBaseMs: Int64 = 0
    private var playbackStartedAt: Date?
    private var activeSpotifyPlayback: SpotifyPlayback?
    private var activeMediaKey: String?
    private var lastSpotifyPollAt: Date = .distantPast
    private var lastSpotifyPollDiagnosticAt: Date = .distantPast
    private var spotifyPollInFlight = false
    private var spotifyPollStartedAt: Date?
    private var spotifyPollGeneration = 0
    private var spotifyPollSequence: Int64 = 0
    private var lookupTask: Task<Void, Never>?
    private var lookupGeneration = 0
    private var snapshotRevision: Int64 = 0
    private var lastSentBluetoothSnapshot: LyricsSnapshot?
    private var lastSentBluetoothSync: LyricsPlaybackSync?
    private var lastSentBluetoothScript: LyricsScriptSnapshot?
    private var lastSentBluetoothWindowToken: LyricsTransportWindowToken?
    private var scriptDeliveryGeneration = 0
    private var bleProtocolReady = false
    private var didAutoConnectCxr = false
    private var suppressSpotifyPollingUntil: Date?
    private var spotifyPollTask: Task<Void, Never>?
    private var autoplayAfterManualLookup = false
    private var manualLookupStartProgressMs: Int64 = 0
    private var backgroundPollingTask: Task<Void, Never>?
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var glassesCapabilities = Set<String>()
    private var lyricsResultCache: [String: CompositeLyricsFetchResult] = [:]
    private var lyricsResultCacheOrder: [String] = []
    private let lyricsResultCacheLimit = 32
    private let backgroundAudio = BackgroundAudioKeepAlive()

    init(defaults: UserDefaults = .standard, keychain: KeychainSecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.keychain = keychain
        let spotifyClient = SpotifyClient(defaults: defaults)
        let glassesTransport = LyricsGlassesTransport()
        self.spotifyClient = spotifyClient
        self.glassesTransport = glassesTransport
        let storedRevision = defaults.object(forKey: Keys.snapshotRevision) as? NSNumber
        snapshotRevision = max(storedRevision?.int64Value ?? 0, Int64(Date().timeIntervalSince1970 * 1000))
        defaults.set(snapshotRevision, forKey: Keys.snapshotRevision)
        spotifyClientId = spotifyClient.clientId
        spotifyAuthStatus = spotifyClient.status
        spotifyLyricsInput = defaults.string(forKey: Keys.spotifyLyricsInput) ?? ""
        spotifyLyricsMode = SpotifyLyricsSourceMode(rawValue: defaults.string(forKey: Keys.spotifyLyricsMode) ?? "") ?? .backend
        spotifyLyricsBackendURL = defaults.string(forKey: Keys.spotifyLyricsBackendURL) ?? "http://127.0.0.1:8787/lyrics"
        spotifySpDc = (try? keychain.string(account: Keys.spotifySpDcAccount)) ?? ""
        musixmatchEmail = defaults.string(forKey: Keys.musixmatchEmail) ?? ""
        musixmatchPassword = defaults.string(forKey: Keys.musixmatchPassword) ?? ""

        spotifyClient.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.spotifyAuthStatus = status
            }
            .store(in: &cancellables)

        glassesTransport.onMessage = { [weak self] message in
            self?.handleGlassesMessage(message)
        }
        glassesTransport.onSubscribed = { [weak self] in
            self?.completeBleHandshake()
        }
        glassesTransport.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.deviceStatus = status
                if status.connectionState != .connected {
                    self.markBleProtocolNotReady()
                }
            }
            .store(in: &cancellables)

        if !Self.isRunningUnitTests {
            startRuntimeTicker()
            observeApplicationLifecycle()
        }
    }

    #if DEBUG
    static func screenshotPreviewStore() -> LyricsRuntimeStore {
        let suiteName = "com.anezium.rokidlyrics.screenshots"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("pk_client_id_redacted", forKey: "spotify.clientId")
        defaults.set("spotify:track:track_id_redacted", forKey: Keys.spotifyLyricsInput)
        defaults.set(SpotifyLyricsSourceMode.backend.rawValue, forKey: Keys.spotifyLyricsMode)
        defaults.set("http://127.0.0.1:8787/lyrics", forKey: Keys.spotifyLyricsBackendURL)
        defaults.set("redacted@example.com", forKey: Keys.musixmatchEmail)
        defaults.set("redacted-password", forKey: Keys.musixmatchPassword)

        let store = LyricsRuntimeStore(
            defaults: defaults,
            keychain: KeychainSecretStore(service: "com.anezium.rokidlyrics.screenshots")
        )
        store.applyScreenshotFixture()
        DispatchQueue.main.async {
            store.applyScreenshotFixture()
        }
        return store
    }

    private func applyScreenshotFixture() {
        spotifyAuthStatus = .connected
        spotifyNowPlayingLabel = "Spotify monitor: sample playback"
        isPlaying = true
        playbackSource = .spotify
        activeSpotifyPlayback = SpotifyPlayback(
            snapshot: MediaPlaybackSnapshot(
                source: "SPOTIFY",
                trackId: "track_id_redacted",
                title: "Sample Track",
                artist: "Sample Artist",
                album: "Sample Album",
                durationSeconds: 192,
                positionMs: 84_200,
                isPlaying: true,
                isrc: "ISRC_REDACTED"
            ),
            observedAt: Date()
        )
        activeMediaKey = "spotify|track_id_redacted"
        statusLabel = "Lyrics loaded. HTTP 200 / LINE_SYNCED / 47 lines."
        providerStatusLabel = "Providers: Spotify -> LRCLIB -> Netease -> Musixmatch."
        deviceStatus = DeviceStatus(
            connectionState: .connected,
            statusLabel: "CXR-L ready. Rokid Lyrics glasses app is running.",
            bluetoothClientCount: 1,
            notificationAccessEnabled: false,
            lastError: nil
        )
        snapshot = LyricsSnapshot(
            sessionState: .playing,
            mediaKey: "spotify|track_id_redacted",
            revision: 1,
            trackTitle: "Sample Track",
            artistName: "Sample Artist",
            albumName: "Sample Album",
            durationSeconds: 192,
            provider: "SPOTIFY",
            sourceSummary: "Spotify color-lyrics: status=200 syncType=LINE_SYNCED line_count=47.",
            synced: true,
            progressMs: 84_200,
            capturedAtEpochMs: nowEpochMs(),
            currentLineIndex: 1,
            lines: [
                LyricsLine(startTimeMs: 80_000, text: "Previous synced line"),
                LyricsLine(startTimeMs: 84_000, text: "Current synced line"),
                LyricsLine(startTimeMs: 88_000, text: "Next synced line"),
                LyricsLine(startTimeMs: 92_000, text: "Upcoming synced line"),
            ],
            plainLyrics: "",
            errorMessage: nil
        )
    }
    #endif

    var canLookup: Bool {
        !isLookingUp &&
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasLyrics: Bool {
        !snapshot.lines.isEmpty || !snapshot.plainLyrics.isEmpty
    }

    var canUseLocalControls: Bool {
        playbackSource == .manual && hasLyrics
    }

    var spotifyConnected: Bool {
        spotifyAuthStatus == .connected
    }

    var spotifyButtonTitle: String {
        spotifyConnected ? "DISCONNECT" : "CONNECT"
    }

    var spotifyLyricsModeLabel: String {
        switch spotifyLyricsMode {
        case .backend:
            return spotifyLyricsBackendURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Backend URL required."
                : "Private backend keeps sp_dc out of the iOS app."
        case .direct:
            return SpotifySpDcCookie.extractValue(from: spotifySpDc) == nil
                ? "Direct mode needs user-provided sp_dc stored in Keychain. Spotify OAuth does not expose this cookie."
                : "Direct mode uses user-provided sp_dc from Keychain."
        }
    }

    var currentSpotifyTrackLabel: String {
        guard spotifyConnected else {
            return "Connect Spotify to use the current track automatically."
        }
        guard let playback = activeSpotifyPlayback?.liveSnapshot else {
            return "Current Spotify track will be read from the existing playback integration."
        }
        return "\(playback.title) / \(playback.artist) • \(playback.trackId)"
    }

    var canFetchCurrentSpotifyLyrics: Bool {
        spotifyConnected && !isLookingUp
    }

    var canFetchSpotifyLyricsInput: Bool {
        guard !isLookingUp else { return false }
        return SpotifyTrackIdentifier.extract(from: spotifyLyricsInput) != nil
    }

    var providerBadge: String {
        if isLookingUp { return "LOOKUP" }
        if snapshot.errorMessage != nil { return "ERROR" }
        if snapshot.synced { return snapshot.provider.isEmpty ? "SYNC" : snapshot.provider }
        if !snapshot.plainLyrics.isEmpty { return "PLAIN" }
        if spotifyConnected { return "SPOTIFY" }
        return "NO SOURCE"
    }

    var timelineDurationMs: Int64 {
        if let durationSeconds = snapshot.durationSeconds, durationSeconds > 0 {
            return Int64(durationSeconds) * 1000
        }
        if let lastLine = snapshot.lines.last {
            return max(lastLine.startTimeMs + 10000, 30000)
        }
        return 30000
    }

    var progressFraction: Double {
        guard timelineDurationMs > 0 else { return 0 }
        return Double(snapshot.progressMs) / Double(timelineDurationMs)
    }

    var visibleLines: [LyricDisplayLine] {
        if snapshot.sessionState == .loading {
            return [
                LyricDisplayLine(id: -2, text: "", role: .previous),
                LyricDisplayLine(id: -1, text: "Searching...", role: .current),
                LyricDisplayLine(id: 0, text: "", role: .next),
            ]
        }

        if snapshot.lines.isEmpty {
            let text = snapshot.plainLyrics
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init) ?? "No synced lyrics loaded"
            return [
                LyricDisplayLine(id: -2, text: "", role: .previous),
                LyricDisplayLine(id: -1, text: text, role: hasLyrics ? .current : .empty),
                LyricDisplayLine(id: 0, text: "", role: .next),
            ]
        }

        let currentIndex = snapshot.currentLineIndex
        return [
            displayLine(at: currentIndex - 1, role: .previous),
            displayLine(at: currentIndex, role: .current),
            displayLine(at: currentIndex + 1, role: .next),
            displayLine(at: currentIndex + 2, role: .next),
        ]
    }

    func connectOrDisconnectSpotify() {
        if spotifyConnected {
            spotifyClient.disconnect()
            activeSpotifyPlayback = nil
            activeMediaKey = nil
            lookupTask?.cancel()
            isLookingUp = false
            spotifyNowPlayingLabel = "Spotify disconnected."
            if playbackSource == .spotify {
                playbackSource = .manual
                isPlaying = false
            }
        } else {
            spotifyClient.connect()
        }
    }

    func handleOpenURL(_ url: URL) {
        if handleLookupPayloadURL(url) {
            return
        }
        if glassesTransport.handleOpenURL(url) {
            return
        }
        Task {
            await spotifyClient.handleOpenURL(url)
            if spotifyClient.isConnected, !isSpotifyPollingSuppressed() {
                spotifyMonitoringEnabled = true
                scheduleSpotifyPoll(force: true)
            }
        }
    }

    private func handleLookupPayloadURL(_ url: URL) -> Bool {
        guard let deepLink = LyricsRuntimeDeepLink(url: url) else { return false }
        suppressSpotifyPollingUntil = Date().addingTimeInterval(60)
        activeSpotifyPlayback = nil
        activeMediaKey = nil
        switch deepLink {
        case .sample:
            sampleTrack()

        case .lookup(let payload):
            title = payload.title
            artist = payload.artist
            album = payload.album
            durationSecondsText = payload.duration
            autoplayAfterManualLookup = payload.autoplay
            manualLookupStartProgressMs = payload.progressMs

        case .spotifyLyrics(let payload):
            spotifyLyricsInput = payload.input
            if let mode = payload.mode {
                spotifyLyricsMode = mode
            }
            Task { @MainActor in
                await fetchSpotifyLyricsInput()
            }
            return true
        }
        Task { @MainActor in
            await lookup()
        }
        return true
    }

    func connectCxr() {
        glassesTransport.authenticateCxr()
    }

    func autoConnectCxrIfNeeded() {
        guard !Self.isRunningUnitTests, !didAutoConnectCxr else { return }
        didAutoConnectCxr = true
        connectCxr()
    }

    func refreshSpotifyNow() {
        scheduleSpotifyPoll(force: true)
    }

    func fetchCurrentSpotifyLyricsNow() async {
        guard canFetchCurrentSpotifyLyrics else { return }
        lookupTask?.cancel()
        do {
            guard let playback = try await spotifyClient.fetchCurrentlyPlaying() else {
                handleSpotifyIdle()
                return
            }
            let media = playback.liveSnapshot
            spotifyLyricsInput = media.trackId
            activeSpotifyPlayback = playback
            playbackSource = .spotify
            isPlaying = media.isPlaying
            spotifyNowPlayingLabel = "\(media.title) / \(media.artist)"
            title = media.title
            artist = media.artist
            album = media.album
            durationSecondsText = media.durationSeconds.map(String.init) ?? ""
            activeMediaKey = media.lookupKey
            let lookupGeneration = beginSpotifyTimeline(for: media)
            await performLookup(
                request: media.lookupRequest,
                media: media,
                expectedMediaKey: media.lookupKey,
                generation: lookupGeneration,
                lookupRevision: snapshot.revision,
                sendInitialSnapshot: false
            )
        } catch {
            spotifyNowPlayingLabel = error.localizedDescription
            statusLabel = error.localizedDescription
        }
    }

    func fetchSpotifyLyricsInput() async {
        guard canFetchSpotifyLyricsInput else { return }
        playbackSource = .manual
        activeMediaKey = nil
        activeSpotifyPlayback = nil
        lookupTask?.cancel()
        isPlaying = false
        playbackBaseMs = 0
        playbackStartedAt = nil

        guard let trackId = SpotifyTrackIdentifier.extract(from: spotifyLyricsInput) else { return }
        let request = LyricsLookupRequest(
            title: "Spotify track \(trackId)",
            artist: "",
            durationSeconds: nil,
            spotifyTrackId: trackId
        )
        let media = MediaPlaybackSnapshot(
            source: "SPOTIFY",
            trackId: trackId,
            title: request.title,
            artist: request.artist,
            album: "",
            durationSeconds: nil,
            positionMs: 0,
            isPlaying: false,
            isrc: nil
        )
        title = request.title
        artist = request.artist
        album = ""
        durationSecondsText = ""
        await performLookup(request: request, media: media, expectedMediaKey: nil)
    }

    func lookup() async {
        guard canLookup else { return }
        let shouldAutoplay = autoplayAfterManualLookup
        let startProgressMs = manualLookupStartProgressMs.coerceAtLeast(0)
        autoplayAfterManualLookup = false
        manualLookupStartProgressMs = 0
        playbackSource = .manual
        activeMediaKey = nil
        activeSpotifyPlayback = nil
        lookupTask?.cancel()
        isPlaying = false
        playbackBaseMs = 0
        playbackStartedAt = nil

        let request = LyricsLookupRequest(
            title: title,
            artist: artist,
            album: album,
            durationSeconds: Int(durationSecondsText.trimmingCharacters(in: .whitespacesAndNewlines)),
            isrc: nil
        )
        await performLookup(request: request, media: nil, expectedMediaKey: nil)
        if shouldAutoplay, hasLyrics {
            playbackBaseMs = startProgressMs
            playbackStartedAt = Date()
            isPlaying = true
            applyProgress(startProgressMs, state: .playing)
        }
    }

    func togglePlayback() {
        guard canUseLocalControls else { return }
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard canUseLocalControls else { return }
        isPlaying = true
        playbackStartedAt = Date()
        snapshot = snapshot.copy(sessionState: .playing, capturedAtEpochMs: nowEpochMs(), clearError: true)
        statusLabel = "Playing local sync preview."
        sendBluetoothSyncIfNeeded(force: true)
    }

    func pause() {
        updateManualProgress()
        isPlaying = false
        playbackStartedAt = nil
        snapshot = snapshot.copy(sessionState: hasLyrics ? .ready : .idle, capturedAtEpochMs: nowEpochMs())
        statusLabel = hasLyrics ? "Paused." : "Enter a track or connect Spotify."
        sendBluetoothSyncIfNeeded(force: true)
    }

    func restart() {
        guard playbackSource == .manual else { return }
        playbackBaseMs = 0
        playbackStartedAt = isPlaying ? Date() : nil
        applyProgress(0, state: isPlaying ? .playing : .ready)
    }

    func seek(to fraction: Double) {
        guard playbackSource == .manual else { return }
        let clamped = min(max(fraction, 0), 1)
        let progressMs = Int64(Double(timelineDurationMs) * clamped)
        playbackBaseMs = progressMs
        playbackStartedAt = isPlaying ? Date() : nil
        applyProgress(progressMs, state: isPlaying ? .playing : .ready)
    }

    func tick() {
        // Keep a silent audio session alive while we're actively monitoring Spotify so iOS
        // doesn't suspend the app in the background — otherwise polling stops ~30s after
        // backgrounding and an off-app track change is never noticed until the user reopens
        // the app. `.mixWithOthers` means this never interrupts the music itself.
        backgroundAudio.update(active: spotifyMonitoringEnabled && spotifyClient.isConnected)
        if spotifyMonitoringEnabled, spotifyClient.isConnected {
            applySpotifyLiveProgress()
            if Date().timeIntervalSince(lastSpotifyPollAt) >= RuntimeTuning.spotifyPollIntervalSeconds {
                scheduleSpotifyPoll(force: false)
            }
        } else if isPlaying {
            updateManualProgress()
        }
    }

    func sampleTrack() {
        title = "Blinding Lights"
        artist = "The Weeknd"
        album = "After Hours"
        durationSecondsText = "200"
    }

    private func startRuntimeTicker() {
        runtimeTicker = Timer.publish(every: RuntimeTuning.tickIntervalSeconds, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    private func observeApplicationLifecycle() {
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleApplicationDidBecomeActive()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleApplicationWillResignActive()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleApplicationDidEnterBackground()
                }
            }
            .store(in: &cancellables)
    }

    private func handleApplicationDidBecomeActive() {
        stopBackgroundSpotifyPolling()
        scheduleSpotifyPoll(force: true)
    }

    private func handleApplicationWillResignActive() {
        guard spotifyMonitoringEnabled, spotifyClient.isConnected else { return }
        backgroundAudio.update(active: true)
        scheduleSpotifyPoll(force: true)
        startBackgroundSpotifyPollingIfNeeded()
    }

    private func handleApplicationDidEnterBackground() {
        backgroundAudio.update(active: spotifyMonitoringEnabled && spotifyClient.isConnected)
        scheduleSpotifyPoll(force: true)
        startBackgroundSpotifyPollingIfNeeded()
    }

    private func scheduleSpotifyPoll(force: Bool) {
        if force {
            spotifyPollTask?.cancel()
            spotifyPollInFlight = false
            spotifyPollStartedAt = nil
        } else if spotifyPollInFlight {
            guard shouldResetStaleSpotifyPoll() else { return }
            let age = spotifyPollStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            print("[RokidLyricsSpotify] poll watchdog reset age=\(String(format: "%.1f", age))s app=\(applicationStateLabel) bg=\(backgroundTimeRemainingLabel)")
            spotifyPollTask?.cancel()
            spotifyPollInFlight = false
            spotifyPollStartedAt = nil
        }
        spotifyPollGeneration += 1
        let generation = spotifyPollGeneration
        spotifyPollTask = Task { @MainActor [weak self] in
            await self?.pollSpotify(force: force, generation: generation)
        }
    }

    private func startBackgroundSpotifyPollingIfNeeded() {
        guard spotifyMonitoringEnabled,
              spotifyClient.isConnected,
              backgroundPollingTask == nil
        else { return }

        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "RokidLyricsSpotifyPolling") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundSpotifyPollingTask(expired: true)
            }
        }

        backgroundPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishBackgroundSpotifyPollingLoop() }
            while !Task.isCancelled,
                  self.spotifyMonitoringEnabled,
                  self.spotifyClient.isConnected,
                  UIApplication.shared.applicationState != .active
            {
                self.backgroundAudio.update(active: true)
                self.tick()
                if UIApplication.shared.backgroundTimeRemaining < RuntimeTuning.minimumBackgroundTimeRemainingSeconds {
                    self.endBackgroundSpotifyPollingTask(expired: false)
                }
                try? await Task.sleep(nanoseconds: RuntimeTuning.backgroundTickIntervalNanoseconds)
            }
        }
    }

    private func stopBackgroundSpotifyPolling() {
        backgroundPollingTask?.cancel()
        backgroundPollingTask = nil
        endBackgroundSpotifyPollingTask(expired: false)
    }

    private func finishBackgroundSpotifyPollingLoop() {
        backgroundPollingTask = nil
        endBackgroundSpotifyPollingTask(expired: false)
    }

    private func endBackgroundSpotifyPollingTask(expired: Bool) {
        guard backgroundTaskIdentifier != .invalid else { return }
        let taskIdentifier = backgroundTaskIdentifier
        backgroundTaskIdentifier = .invalid
        UIApplication.shared.endBackgroundTask(taskIdentifier)
        if expired {
            print("[RokidLyricsSpotify] polling background task expired; keeping audio-backed poll loop alive app=\(applicationStateLabel)")
        }
    }

    private func shouldResetStaleSpotifyPoll() -> Bool {
        guard let spotifyPollStartedAt else { return true }
        return Date().timeIntervalSince(spotifyPollStartedAt) >= RuntimeTuning.spotifyPollWatchdogSeconds
    }

    private func beginSpotifyFetchBackgroundTaskIfNeeded() -> UIBackgroundTaskIdentifier {
        guard UIApplication.shared.applicationState != .active else { return .invalid }
        var taskIdentifier: UIBackgroundTaskIdentifier = .invalid
        taskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "RokidLyricsSpotifyFetch") {
            print("[RokidLyricsSpotify] fetch background task expired")
            if taskIdentifier != .invalid {
                UIApplication.shared.endBackgroundTask(taskIdentifier)
                taskIdentifier = .invalid
            }
        }
        return taskIdentifier
    }

    private func endBackgroundTask(_ taskIdentifier: UIBackgroundTaskIdentifier) {
        guard taskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskIdentifier)
    }

    private var applicationStateLabel: String {
        switch UIApplication.shared.applicationState {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }

    private var backgroundTimeRemainingLabel: String {
        let remaining = UIApplication.shared.backgroundTimeRemaining
        guard remaining.isFinite, remaining < .greatestFiniteMagnitude else { return "inf" }
        return "\(String(format: "%.1f", remaining))s"
    }

    private func shouldLogSpotifyPoll(media: MediaPlaybackSnapshot?, force: Bool, error: Error?) -> Bool {
        if force { return true }
        if error != nil {
            return Date().timeIntervalSince(lastSpotifyPollDiagnosticAt) >= RuntimeTuning.spotifyPollErrorDiagnosticIntervalSeconds
        }
        if let media, media.lookupKey != activeMediaKey { return true }
        guard UIApplication.shared.applicationState != .active else { return false }
        return Date().timeIntervalSince(lastSpotifyPollDiagnosticAt) >= RuntimeTuning.spotifyPollDiagnosticIntervalSeconds
    }

    private func markSpotifyPollDiagnosticLogged() {
        lastSpotifyPollDiagnosticAt = Date()
    }

    private func nextSpotifyPollSequence() -> Int64 {
        spotifyPollSequence += 1
        return spotifyPollSequence
    }

    private func pollSpotify(force: Bool, generation: Int? = nil) async {
        guard !isSpotifyPollingSuppressed() else {
            spotifyPollTask = nil
            return
        }
        guard spotifyMonitoringEnabled, spotifyClient.isConnected, !spotifyPollInFlight else {
            spotifyPollTask = nil
            return
        }
        if !force, Date().timeIntervalSince(lastSpotifyPollAt) < RuntimeTuning.spotifyPollIntervalSeconds {
            spotifyPollTask = nil
            return
        }

        let sequence = nextSpotifyPollSequence()
        let pollStartedAt = Date()
        let fetchBackgroundTask = beginSpotifyFetchBackgroundTaskIfNeeded()
        spotifyPollInFlight = true
        spotifyPollStartedAt = pollStartedAt
        lastSpotifyPollAt = pollStartedAt
        defer {
            endBackgroundTask(fetchBackgroundTask)
            if generation == nil || generation == spotifyPollGeneration {
                spotifyPollInFlight = false
                spotifyPollStartedAt = nil
                spotifyPollTask = nil
            }
        }

        do {
            guard let playback = try await spotifyClient.fetchCurrentlyPlaying() else {
                handleSpotifyIdle()
                return
            }
            guard !Task.isCancelled, generation == nil || generation == spotifyPollGeneration else { return }
            let media = playback.liveSnapshot
            if shouldLogSpotifyPoll(media: media, force: force, error: nil) {
                let elapsed = Date().timeIntervalSince(pollStartedAt)
                print("[RokidLyricsSpotify] poll ok seq=\(sequence) force=\(force) app=\(applicationStateLabel) bg=\(backgroundTimeRemainingLabel) elapsed=\(String(format: "%.2f", elapsed))s track=\"\(media.title)\" artist=\"\(media.artist)\" progressMs=\(media.positionMs) duration=\(media.durationSeconds ?? 0) playing=\(media.isPlaying) changed=\(media.lookupKey != activeMediaKey)")
                markSpotifyPollDiagnosticLogged()
            }
            handleSpotifyPlayback(playback)
        } catch {
            if error is CancellationError { return }
            if shouldLogSpotifyPoll(media: nil, force: force, error: error) {
                let elapsed = Date().timeIntervalSince(pollStartedAt)
                print("[RokidLyricsSpotify] poll error seq=\(sequence) force=\(force) app=\(applicationStateLabel) bg=\(backgroundTimeRemainingLabel) elapsed=\(String(format: "%.2f", elapsed))s error=\(error.localizedDescription)")
                markSpotifyPollDiagnosticLogged()
            }
            if let spotifyError = error as? SpotifyClientError {
                switch spotifyError {
                case .noActivePlayback:
                    handleSpotifyIdle()
                    return
                case .rateLimited(let wait):
                    let waitSeconds = TimeInterval(wait) ?? RuntimeTuning.spotifyRateLimitFallbackSeconds
                    suppressSpotifyPollingUntil = Date().addingTimeInterval(
                        max(waitSeconds, RuntimeTuning.spotifyRateLimitFallbackSeconds)
                    )
                    spotifyNowPlayingLabel = spotifyError.localizedDescription
                    if playbackSource != .spotify {
                        statusLabel = spotifyError.localizedDescription
                    }
                    return
                default:
                    break
                }
            }
            spotifyNowPlayingLabel = error.localizedDescription
            if playbackSource != .spotify {
                statusLabel = error.localizedDescription
            }
        }
    }

    private func isSpotifyPollingSuppressed() -> Bool {
        guard let suppressSpotifyPollingUntil else { return false }
        if suppressSpotifyPollingUntil > Date() {
            return true
        }
        self.suppressSpotifyPollingUntil = nil
        return false
    }

    private func handleSpotifyPlayback(_ playback: SpotifyPlayback) {
        let media = playback.liveSnapshot
        let matchesCurrentVisibleTrack = activeMediaKey != nil && visibleTrackMatches(media)
        activeSpotifyPlayback = playback
        playbackSource = .spotify
        isPlaying = media.isPlaying
        spotifyNowPlayingLabel = "\(media.title) / \(media.artist)"
        title = media.title
        artist = media.artist
        album = media.album
        durationSecondsText = media.durationSeconds.map(String.init) ?? ""

        if activeMediaKey != media.lookupKey {
            if matchesCurrentVisibleTrack {
                applyMediaProgressForCurrentTimeline(media)
                return
            }
            lookupTask?.cancel()
            activeMediaKey = media.lookupKey
            let lookupGeneration = beginSpotifyTimeline(for: media)
            lookupTask = Task { @MainActor in
                await self.performLookup(
                    request: media.lookupRequest,
                    media: media,
                    expectedMediaKey: media.lookupKey,
                    generation: lookupGeneration,
                    lookupRevision: self.snapshot.revision,
                    sendInitialSnapshot: false
                )
            }
        } else {
            applyMediaProgress(media)
        }
    }

    private func handleMediaPlaybackHint(_ hint: MediaPlaybackHint) {
        let media = MediaPlaybackSnapshot(
            source: hint.source.ifBlank("GLASSES_AVRCP"),
            trackId: hint.trackId,
            title: hint.title.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: hint.artistName.trimmingCharacters(in: .whitespacesAndNewlines),
            album: hint.albumName.trimmingCharacters(in: .whitespacesAndNewlines),
            durationSeconds: hint.durationSeconds,
            positionMs: hint.progressMs.coerceAtLeast(0),
            isPlaying: hint.isPlaying,
            isrc: nil
        )
        guard !media.title.isEmpty, !media.artist.isEmpty else { return }

        let matchesCurrentVisibleTrack = activeMediaKey != nil && visibleTrackMatches(media)
        playbackSource = .spotify
        isPlaying = media.isPlaying
        spotifyNowPlayingLabel = "\(media.title) / \(media.artist)"
        title = media.title
        artist = media.artist
        album = media.album
        durationSecondsText = media.durationSeconds.map(String.init) ?? ""

        if activeMediaKey == media.lookupKey || matchesCurrentVisibleTrack {
            applyMediaProgressForCurrentTimeline(media)
            return
        }

        activeSpotifyPlayback = nil
        lookupTask?.cancel()
        activeMediaKey = media.lookupKey
        let lookupGeneration = beginSpotifyTimeline(for: media)
        lookupTask = Task { @MainActor in
            await self.performLookup(
                request: media.lookupRequest,
                media: media,
                expectedMediaKey: media.lookupKey,
                generation: lookupGeneration,
                lookupRevision: self.snapshot.revision,
                sendInitialSnapshot: false
            )
        }
        scheduleSpotifyPoll(force: true)
    }

    private func beginSpotifyTimeline(for media: MediaPlaybackSnapshot) -> Int {
        lookupGeneration += 1
        invalidateBluetoothTimeline(dropQueuedWrites: true)
        let revision = nextSnapshotRevision()
        isLookingUp = true
        statusLabel = "Querying \(lyricsProviderNames(for: media.lookupRequest))..."
        snapshot = LyricsSnapshot(
            sessionState: .loading,
            mediaKey: media.lookupKey,
            revision: revision,
            trackTitle: media.title,
            artistName: media.artist,
            albumName: media.album,
            durationSeconds: media.durationSeconds,
            sourceSummary: "Resolving lyrics for \(media.source)...",
            synced: false,
            progressMs: media.positionMs.coerceAtLeast(0),
            capturedAtEpochMs: nowEpochMs(),
            currentLineIndex: -1
        )
        sendBluetoothSnapshot(force: true, priority: true)
        return lookupGeneration
    }

    private func handleSpotifyIdle() {
        guard playbackSource == .spotify || activeSpotifyPlayback != nil else { return }
        playbackSource = .manual
        activeSpotifyPlayback = nil
        activeMediaKey = nil
        lookupTask?.cancel()
        isPlaying = false
        isLookingUp = false
        playbackStartedAt = nil
        playbackBaseMs = 0
        spotifyNowPlayingLabel = "Spotify idle."
        title = ""
        artist = ""
        album = ""
        durationSecondsText = ""
        invalidateBluetoothTimeline(dropQueuedWrites: true)
        snapshot = LyricsSnapshot(
            sessionState: .idle,
            revision: nextSnapshotRevision(),
            sourceSummary: "Spotify is not playing.",
            capturedAtEpochMs: nowEpochMs()
        )
        statusLabel = "Spotify is not playing."
        sendBluetoothSnapshot(force: true, priority: true)
    }

    private func performLookup(
        request: LyricsLookupRequest,
        media: MediaPlaybackSnapshot?,
        expectedMediaKey: String?,
        generation providedGeneration: Int? = nil,
        lookupRevision providedLookupRevision: Int64? = nil,
        sendInitialSnapshot: Bool = true
    ) async {
        let generation: Int
        if let providedGeneration {
            generation = providedGeneration
        } else {
            lookupGeneration += 1
            generation = lookupGeneration
        }
        let lookupMediaKey = expectedMediaKey ?? mediaKey(for: request, source: media?.source ?? "manual")
        let lookupRevision = providedLookupRevision ?? nextSnapshotRevision()
        defer {
            if generation == lookupGeneration {
                isLookingUp = false
            }
        }
        isLookingUp = true
        let progressMs = media?.positionMs ?? 0
        let source = media?.source ?? "manual"
        statusLabel = "Querying \(lyricsProviderNames(for: request))..."
        print("[RokidLyricsLookup] start generation=\(generation) source=\(source) key=\"\(lookupMediaKey)\" title=\"\(request.title)\" artist=\"\(request.artist)\" progressMs=\(progressMs)")

        if sendInitialSnapshot {
            invalidateBluetoothTimeline(dropQueuedWrites: true)
            snapshot = snapshot.copy(
                sessionState: .loading,
                mediaKey: lookupMediaKey,
                revision: lookupRevision,
                trackTitle: request.title,
                artistName: request.artist,
                albumName: request.album,
                durationSeconds: request.durationSeconds,
                clearDuration: request.durationSeconds == nil,
                provider: "",
                sourceSummary: "Resolving lyrics for \(source)...",
                synced: false,
                progressMs: progressMs,
                currentLineIndex: -1,
                lines: [],
                plainLyrics: "",
                clearError: true
            )
            sendBluetoothSnapshot(force: true, priority: true)
        }

        let result: CompositeLyricsFetchResult
        if let cached = cachedLyricsResult(for: lookupMediaKey) {
            print("[RokidLyricsLookup] cache hit generation=\(generation) key=\"\(lookupMediaKey)\" lines=\(cached.result.lines.count)")
            result = cached
        } else {
            let composite = CompositeLyricsProvider(providers: lyricsProviders(for: request))
            result = await composite.fetch(request)
        }
        guard !Task.isCancelled, generation == lookupGeneration else { return }
        if cachedLyricsResult(for: lookupMediaKey) == nil,
           !result.result.lines.isEmpty || !result.result.plainLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            storeLyricsResult(result, for: lookupMediaKey)
        }
        if let expectedMediaKey, activeMediaKey != expectedMediaKey {
            return
        }
        if expectedMediaKey == nil, (playbackSource != .manual || activeMediaKey != nil) {
            return
        }

        let resolvedMedia = expectedMediaKey == nil ? media : activeSpotifyPlayback?.liveSnapshot ?? media
        let resolvedProgressMs = resolvedMedia?.positionMs ?? progressMs
        let resolvedIsPlaying = resolvedMedia?.isPlaying ?? media?.isPlaying ?? false
        providerStatusLabel = result.attemptSummaries
            .map { "\($0.provider): \($0.outcome.rawValue)" }
            .joined(separator: " | ")
            .ifBlank("Providers: no attempts yet.")

        let estimatedLines = result.result.lines.isEmpty
            ? PlainLyricsTiming.estimatedLines(
                from: result.result.plainLyrics,
                durationSeconds: result.result.durationSeconds ?? request.durationSeconds
            )
            : []
        let resolvedLines = result.result.lines.isEmpty ? estimatedLines : result.result.lines
        let resolvedPlainLyrics = result.result.plainLyrics
        let hasVisibleResult = !resolvedLines.isEmpty ||
            !resolvedPlainLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let usesEstimatedTiming = result.result.lines.isEmpty && !estimatedLines.isEmpty
        let resolvedSynced = (result.result.synced || usesEstimatedTiming) && !resolvedLines.isEmpty
        let sourceSummary = usesEstimatedTiming
            ? "\(result.result.sourceSummary) Plain lyrics are auto-scrolled with estimated timing."
            : result.result.sourceSummary
        let resolvedSessionState: LyricsSessionState = {
            guard hasVisibleResult else { return .error }
            return resolvedIsPlaying ? .playing : .ready
        }()
        let lineIndex = LrcParser.index(for: resolvedLines, progressMs: resolvedProgressMs)
        snapshot = LyricsSnapshot(
            sessionState: resolvedSessionState,
            mediaKey: lookupMediaKey,
            revision: lookupRevision,
            trackTitle: result.result.trackTitle,
            artistName: result.result.artistName,
            albumName: result.result.albumName,
            durationSeconds: result.result.durationSeconds,
            provider: result.result.provider,
            sourceSummary: sourceSummary,
            synced: resolvedSynced,
            progressMs: resolvedProgressMs,
            capturedAtEpochMs: nowEpochMs(),
            currentLineIndex: lineIndex,
            lines: resolvedLines,
            plainLyrics: resolvedPlainLyrics,
            errorMessage: hasVisibleResult ? nil : sourceSummary
        )
        if !hasVisibleResult {
            statusLabel = "No lyrics found for this track."
        } else if usesEstimatedTiming {
            statusLabel = "Plain lyrics ready with estimated scrolling."
        } else if resolvedSynced {
            statusLabel = "Synced lyrics ready."
        } else {
            statusLabel = "Plain lyrics ready."
        }
        print("[RokidLyricsLookup] complete generation=\(generation) provider=\(result.result.provider) synced=\(resolvedSynced) lines=\(resolvedLines.count) progressMs=\(resolvedProgressMs) lineIndex=\(lineIndex)")
        sendBluetoothSnapshot(force: true)
        if let resolvedMedia {
            applyMediaProgress(resolvedMedia)
        }
    }

    private var musixmatchCredentials: MusixmatchCredentials? {
        let email = musixmatchEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !musixmatchPassword.isEmpty else { return nil }
        return MusixmatchCredentials(email: email, password: musixmatchPassword)
    }

    private func lyricsProviders(for request: LyricsLookupRequest) -> [LyricsProvider] {
        var providers: [LyricsProvider] = []
        if request.spotifyTrackId?.takeUnlessBlank() != nil {
            providers.append(
                SpotifyLyricsProvider(
                    mode: spotifyLyricsMode,
                    backendBaseURL: spotifyLyricsBackendURL,
                    spDc: spotifySpDc
                )
            )
        }
        providers.append(LrcLibLyricsClient())
        providers.append(NeteaseLyricsProvider())
        providers.append(MusixmatchLyricsProvider(credentials: musixmatchCredentials))
        return providers
    }

    private func lyricsProviderNames(for request: LyricsLookupRequest) -> String {
        lyricsProviders(for: request).map(\.providerName).joined(separator: ", ")
    }

    private func persistSpotifySpDc() {
        do {
            if let normalized = SpotifySpDcCookie.extractValue(from: spotifySpDc) {
                try keychain.set(normalized, account: Keys.spotifySpDcAccount)
            } else {
                try keychain.delete(account: Keys.spotifySpDcAccount)
            }
        } catch {
            providerStatusLabel = "Spotify sp_dc Keychain error: \(error.localizedDescription)"
        }
    }

    private func cachedLyricsResult(for key: String) -> CompositeLyricsFetchResult? {
        lyricsResultCache[key]
    }

    private func storeLyricsResult(_ result: CompositeLyricsFetchResult, for key: String) {
        if lyricsResultCache[key] == nil {
            lyricsResultCacheOrder.append(key)
            if lyricsResultCacheOrder.count > lyricsResultCacheLimit {
                let evicted = lyricsResultCacheOrder.removeFirst()
                lyricsResultCache.removeValue(forKey: evicted)
            }
        }
        lyricsResultCache[key] = result
    }

    private func applySpotifyLiveProgress() {
        guard let playback = activeSpotifyPlayback else { return }
        applyMediaProgress(playback.liveSnapshot)
    }

    private func applyMediaProgress(_ media: MediaPlaybackSnapshot) {
        guard playbackSource == .spotify else { return }
        guard activeMediaKey == nil || activeMediaKey == media.lookupKey else { return }
        applyMediaProgressForCurrentTimeline(media)
    }

    private func applyMediaProgressForCurrentTimeline(_ media: MediaPlaybackSnapshot) {
        let progressMs = media.positionMs.coerceAtLeast(0)
        isPlaying = media.isPlaying
        let state: LyricsSessionState = media.isPlaying ? .playing : .ready
        applyProgress(progressMs, state: hasLyrics ? state : snapshot.sessionState)
    }

    private func visibleTrackMatches(_ media: MediaPlaybackSnapshot) -> Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        guard TextMatch.score(request: title, candidate: media.title) >= 88,
              TextMatch.score(request: artist, candidate: media.artist) >= 70
        else { return false }
        guard let currentDuration = Int(durationSecondsText),
              let nextDuration = media.durationSeconds,
              currentDuration > 0,
              nextDuration > 0
        else { return true }
        return abs(currentDuration - nextDuration) <= 3
    }

    private func updateManualProgress() {
        guard let playbackStartedAt else { return }
        let elapsedMs = Int64(Date().timeIntervalSince(playbackStartedAt) * 1000)
        let next = min(playbackBaseMs + elapsedMs, timelineDurationMs)
        if next >= timelineDurationMs {
            isPlaying = false
            self.playbackStartedAt = nil
            playbackBaseMs = timelineDurationMs
            applyProgress(timelineDurationMs, state: .ready)
        } else {
            applyProgress(next, state: .playing)
        }
    }

    private func applyProgress(_ progressMs: Int64, state: LyricsSessionState) {
        let currentLineIndex = LrcParser.index(for: snapshot.lines, progressMs: progressMs)
        snapshot = snapshot.copy(
            sessionState: state,
            progressMs: progressMs,
            capturedAtEpochMs: nowEpochMs(),
            currentLineIndex: currentLineIndex
        )
        sendBluetoothWindowIfNeeded()
        sendBluetoothSyncIfNeeded()
    }

    private func handleGlassesMessage(_ message: GlassesToPhoneMessage) {
        switch message {
        case let .hello(hello):
            guard hello.protocolVersion == TransportConstants.protocolVersion else {
                glassesTransport.send(.error("Update the phone and glasses apps to the same Lyrics protocol."), priority: true)
                return
            }
            glassesCapabilities = Set(hello.capabilities)
            completeBleHandshake()

        case .mediaHint(let hint):
            handleMediaPlaybackHint(hint)

        case .requestSnapshot:
            sendBluetoothSnapshot(force: true)

        case .requestStatus:
            sendBluetoothStatus()

        case .togglePlayback:
            print("[RokidLyricsBLE] ignored toggle_playback from glasses")
        }
    }

    private func sendBluetoothStatus() {
        guard bleProtocolReady else { return }
        glassesTransport.send(
            .status(
                DeviceStatus(
                    connectionState: .connected,
                    statusLabel: "Rokid Lyrics link ready.",
                    bluetoothClientCount: max(deviceStatus.bluetoothClientCount, 1),
                    notificationAccessEnabled: deviceStatus.notificationAccessEnabled,
                    lastError: nil
                )
            )
        )
    }

    private func sendBluetoothSnapshot(force: Bool = false, priority: Bool = false) {
        guard bleProtocolReady else { return }
        if snapshot.synced, !snapshot.lines.isEmpty, glassesSupportsWindowTransport {
            let scriptSnapshot = snapshot.glassesTransportScriptSnapshot
            let windowWasSent = sendBluetoothWindowIfNeeded(force: force)
            lastSentBluetoothSnapshot = nil
            if glassesSupportsScriptTransport,
               glassesTransport.activeRoute == .cxr,
               force || scriptSnapshot != lastSentBluetoothScript
            {
                scriptDeliveryGeneration += 1
                let deliveryGeneration = scriptDeliveryGeneration
                let scheduledMediaKey = snapshot.mediaKey
                let scheduledRevision = snapshot.revision
                lastSentBluetoothScript = scriptSnapshot
                sendBluetoothScriptAfterLeadIn(
                    scriptSnapshot,
                    deliveryGeneration: deliveryGeneration,
                    mediaKey: scheduledMediaKey,
                    revision: scheduledRevision
                )
            } else if windowWasSent {
                lastSentBluetoothScript = nil
            }
            sendBluetoothSyncIfNeeded(force: true)
            return
        }

        let transportSnapshot = snapshot.synced && !snapshot.lines.isEmpty
            ? snapshot.glassesLegacySnapshot
            : snapshot.glassesTransportSnapshot
        let comparable = transportSnapshot.bluetoothSnapshotComparable
        guard force || comparable != lastSentBluetoothSnapshot else { return }
        scriptDeliveryGeneration += 1
        lastSentBluetoothWindowToken = nil
        lastSentBluetoothSnapshot = comparable
        lastSentBluetoothScript = nil
        lastSentBluetoothSync = nil
        glassesTransport.send(.lyrics(.snapshot(transportSnapshot)), priority: priority)
        if transportSnapshot.synced {
            sendBluetoothSyncIfNeeded(force: true)
        }
    }

    @discardableResult
    private func sendBluetoothWindowIfNeeded(force: Bool = false) -> Bool {
        guard bleProtocolReady, snapshot.synced, !snapshot.lines.isEmpty, glassesSupportsWindowTransport else {
            return false
        }
        let windowToken = snapshot.glassesTransportWindowToken
        guard force || windowToken != lastSentBluetoothWindowToken else { return false }
        lastSentBluetoothWindowToken = windowToken
        let windowSnapshot = snapshot.glassesTransportWindowSnapshot
        print("[RokidLyricsBLE] window route=\(glassesTransport.activeRoute) force=\(force) range=\(windowToken.range.lowerBound)..<\(windowToken.range.upperBound) lines=\(windowSnapshot.lines.count) of=\(snapshot.lines.count) curLine=\(windowSnapshot.currentLineIndex) progressMs=\(snapshot.progressMs)")
        glassesTransport.send(.lyrics(.window(windowSnapshot)), priority: true)
        return true
    }

    private func sendBluetoothScriptAfterLeadIn(
        _ scriptSnapshot: LyricsScriptSnapshot,
        deliveryGeneration: Int,
        mediaKey: String,
        revision: Int64
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + BluetoothScriptTuning.fullScriptLeadInDelaySeconds) { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.bleProtocolReady,
                      self.scriptDeliveryGeneration == deliveryGeneration,
                      self.snapshot.mediaKey == mediaKey,
                      self.snapshot.revision == revision,
                      self.lastSentBluetoothScript == scriptSnapshot
                else { return }
                self.glassesTransport.send(.lyrics(.script(scriptSnapshot)))
            }
        }
    }

    private func sendBluetoothSyncIfNeeded(force: Bool = false) {
        guard bleProtocolReady else { return }
        guard snapshot.synced else { return }
        let sync = snapshot.bluetoothSync
        guard force || shouldSendBluetoothSync(sync) else { return }
        lastSentBluetoothSync = sync
        print("[RokidLyricsBLE] sync route=\(glassesTransport.activeRoute) state=\(sync.sessionState) progressMs=\(sync.progressMs) curLine=\(sync.currentLineIndex) force=\(force)")
        glassesTransport.send(.lyrics(.sync(sync)))
    }

    private func invalidateBluetoothTimeline(dropQueuedWrites: Bool) {
        lastSentBluetoothSnapshot = nil
        lastSentBluetoothSync = nil
        lastSentBluetoothScript = nil
        lastSentBluetoothWindowToken = nil
        scriptDeliveryGeneration += 1
        if dropQueuedWrites {
            glassesTransport.dropQueuedWrites()
        }
    }

    private func markBleProtocolNotReady() {
        bleProtocolReady = false
        glassesCapabilities = []
        invalidateBluetoothTimeline(dropQueuedWrites: false)
        glassesTransport.dropQueuedWrites()
    }

    private func completeBleHandshake() {
        let wasReady = bleProtocolReady
        bleProtocolReady = true
        if glassesCapabilities.isEmpty {
            glassesCapabilities = Self.defaultGlassesCapabilities
        }
        // The handshake can fire twice in quick succession (transport subscribe, then a
        // later glasses `hello`). Only hard-reset / drop in-flight writes on the first
        // transition to ready; a redundant second call just re-affirms state without
        // tearing down a window that may still be streaming over BLE.
        invalidateBluetoothTimeline(dropQueuedWrites: !wasReady)
        glassesTransport.send(
            .helloAck(
                ProtocolHelloAck(
                    protocolVersion: TransportConstants.protocolVersion,
                    appVersion: "0.1.0",
                    capabilities: ["status", "lyrics_snapshot", "lyrics_window", "lyrics_script", "lyrics_sync", "toggle_playback", "ble_gatt"]
                )
            ),
            priority: true
        )
        sendBluetoothStatus()
        sendBluetoothSnapshot(force: true)
    }

    private var glassesSupportsWindowTransport: Bool {
        glassesCapabilities.contains("lyrics_window")
    }

    private var glassesSupportsScriptTransport: Bool {
        glassesCapabilities.contains("lyrics_script")
    }

    private func shouldSendBluetoothSync(_ sync: LyricsPlaybackSync) -> Bool {
        guard let previous = lastSentBluetoothSync else { return true }
        if sync.mediaKey != previous.mediaKey || sync.revision != previous.revision { return true }
        if sync.sessionState != previous.sessionState { return true }
        if sync.sessionState != .playing {
            return abs(sync.progressMs - previous.progressMs) >= BluetoothScriptTuning.syncSeekToleranceMs
        }
        let elapsedAtSourceMs = sync.capturedAtEpochMs - previous.capturedAtEpochMs
        if elapsedAtSourceMs <= 0 {
            return abs(sync.progressMs - previous.progressMs) >= BluetoothScriptTuning.syncSeekToleranceMs
        }
        if elapsedAtSourceMs >= BluetoothScriptTuning.syncHeartbeatIntervalMs { return true }
        let progressDeltaMs = sync.progressMs - previous.progressMs
        return abs(progressDeltaMs - elapsedAtSourceMs) >= BluetoothScriptTuning.syncDriftToleranceMs
    }

    private func displayLine(at index: Int, role: LyricDisplayLine.Role) -> LyricDisplayLine {
        let text = snapshot.lines.indices.contains(index) ? snapshot.lines[index].text : ""
        return LyricDisplayLine(id: index, text: text, role: text.isEmpty ? .empty : role)
    }

    private func nowEpochMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func nextSnapshotRevision() -> Int64 {
        snapshotRevision += 1
        defaults.set(snapshotRevision, forKey: Keys.snapshotRevision)
        return snapshotRevision
    }

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static let defaultGlassesCapabilities: Set<String> = [
        "lyrics_window",
        "lyrics_script",
        "lyrics_sync",
        "request_status",
        "request_snapshot",
        "toggle_playback",
    ]

    private func mediaKey(for request: LyricsLookupRequest, source: String) -> String {
        [
            source,
            request.isrc ?? "",
            request.spotifyTrackId ?? "",
            request.spotifyTrackId == nil ? "" : spotifyLyricsMode.rawValue,
            request.spotifyTrackId == nil || spotifyLyricsMode != .backend ? "" : spotifyLyricsBackendURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            request.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            request.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            request.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            request.durationSeconds.map(String.init) ?? "",
        ].joined(separator: "|")
    }

    private static func isTruthy(_ value: String?) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}

private enum RuntimeTuning {
    static let tickIntervalSeconds: TimeInterval = 0.25
    static let spotifyPollIntervalSeconds: TimeInterval = 0.5
    static let backgroundTickIntervalNanoseconds: UInt64 = 500_000_000
    static let minimumBackgroundTimeRemainingSeconds: TimeInterval = 5
    static let spotifyPollWatchdogSeconds: TimeInterval = 8
    static let spotifyPollDiagnosticIntervalSeconds: TimeInterval = 15
    static let spotifyPollErrorDiagnosticIntervalSeconds: TimeInterval = 5
    static let spotifyRateLimitFallbackSeconds: TimeInterval = 5
}

private enum BluetoothScriptTuning {
    static let maximumLineTextLength = 80
    // Ship the whole song in one window so the glasses are self-sufficient and never
    // run out of lines mid-track (the ~1-minute freeze). When maxLines >= lineCount the
    // window becomes 0..<lineCount with an absolute currentLineIndex, which stays
    // consistent with the `sync` heartbeats that drive the on-glasses highlight. Songs
    // with more lines than this still roll, with a multi-minute buffer.
    static let initialWindowLineCount = 400
    static let initialWindowPreviousLineCount = 1
    static let fullScriptLeadInDelaySeconds = 0.20
    static let syncSeekToleranceMs: Int64 = 1_500
    static let syncDriftToleranceMs: Int64 = 750
    static let syncHeartbeatIntervalMs: Int64 = 5_000
    // Older glasses helpers used this wall-clock timestamp to extrapolate the
    // playback position. The phone already sends the current Spotify progress, so
    // bypass that extrapolation to avoid lyrics appearing early when the glasses
    // clock is ahead of the iPhone clock.
    static let glassesClockCompensationBypassMs: Int64 = 60_000
}

extension LyricsSnapshot {
    var glassesTimelineCapturedAtEpochMs: Int64 {
        guard capturedAtEpochMs > 0 else { return 0 }
        return capturedAtEpochMs + BluetoothScriptTuning.glassesClockCompensationBypassMs
    }

    var glassesTransportSnapshot: LyricsSnapshot {
        func compactLines(_ lines: [LyricsLine]) -> [LyricsLine] {
            lines.map {
                LyricsLine(
                    startTimeMs: $0.startTimeMs,
                    text: $0.text.truncatedForTransport(maxLength: 72)
                )
            }
        }

        guard synced, !lines.isEmpty else {
            return copy(
                albumName: "",
                clearDuration: true,
                provider: provider.truncatedForTransport(maxLength: 24),
                sourceSummary: "",
                plainLyrics: plainLyrics.truncatedForTransport(maxLength: 80)
            )
        }

        let resolvedIndex: Int
        if lines.indices.contains(currentLineIndex) {
            resolvedIndex = currentLineIndex
        } else {
            resolvedIndex = LrcParser.index(for: lines, progressMs: progressMs)
        }

        guard lines.indices.contains(resolvedIndex) else {
            return copy(
                albumName: "",
                clearDuration: true,
                provider: provider.truncatedForTransport(maxLength: 24),
                sourceSummary: "",
                lines: compactLines(Array(lines.prefix(1))),
                plainLyrics: ""
            )
        }

        let visibleLines = [lines[resolvedIndex]]
        return copy(
            albumName: "",
            clearDuration: true,
            provider: provider.truncatedForTransport(maxLength: 24),
            sourceSummary: "",
            currentLineIndex: 0,
            lines: compactLines(visibleLines),
            plainLyrics: ""
        )
    }

    var glassesLegacySnapshot: LyricsSnapshot {
        copy(
            albumName: "",
            clearDuration: true,
            provider: provider.truncatedForTransport(maxLength: 24),
            sourceSummary: "",
            capturedAtEpochMs: glassesTimelineCapturedAtEpochMs,
            lines: lines.map { line in
                LyricsLine(
                    startTimeMs: line.startTimeMs,
                    text: line.text.sanitizedForScriptTransport()
                        .truncatedForTransport(maxLength: 72)
                )
            },
            plainLyrics: plainLyrics.truncatedForTransport(maxLength: 160)
        )
    }

    var glassesTransportWindowToken: LyricsTransportWindowToken {
        let resolvedIndex: Int
        if lines.indices.contains(currentLineIndex) {
            resolvedIndex = currentLineIndex
        } else {
            resolvedIndex = LrcParser.index(for: lines, progressMs: progressMs)
        }
        let window = LyricsTransportWindow.lineRange(
            lineCount: lines.count,
            anchorIndex: resolvedIndex,
            maxLines: BluetoothScriptTuning.initialWindowLineCount,
            previousLines: BluetoothScriptTuning.initialWindowPreviousLineCount
        )
        return LyricsTransportWindowToken(
            mediaKey: mediaKey,
            revision: revision,
            range: window.range
        )
    }

    var glassesTransportWindowSnapshot: LyricsWindowSnapshot {
        let resolvedIndex: Int
        if lines.indices.contains(currentLineIndex) {
            resolvedIndex = currentLineIndex
        } else {
            resolvedIndex = LrcParser.index(for: lines, progressMs: progressMs)
        }
        let window = LyricsTransportWindow.lineRange(
            lineCount: lines.count,
            anchorIndex: resolvedIndex,
            maxLines: BluetoothScriptTuning.initialWindowLineCount,
            previousLines: BluetoothScriptTuning.initialWindowPreviousLineCount
        )
        let visibleLines = Array(lines[window.range])
        return LyricsWindowSnapshot(
            sessionState: sessionState,
            mediaKey: mediaKey,
            revision: revision,
            trackTitle: trackTitle.truncatedForTransport(maxLength: 48),
            artistName: artistName.truncatedForTransport(maxLength: 48),
            provider: provider.truncatedForTransport(maxLength: 24),
            progressMs: progressMs,
            capturedAtEpochMs: glassesTimelineCapturedAtEpochMs,
            currentLineIndex: window.relativeCurrentLineIndex,
            lines: visibleLines.map { line in
                LyricsWindowLine(
                    startTimeMs: line.startTimeMs,
                    text: line.text.sanitizedForScriptTransport()
                        .truncatedForTransport(maxLength: 72)
                )
            }
        )
    }

    var glassesTransportScriptSnapshot: LyricsScriptSnapshot {
        let resolvedIndex: Int
        if lines.indices.contains(currentLineIndex) {
            resolvedIndex = currentLineIndex
        } else {
            resolvedIndex = LrcParser.index(for: lines, progressMs: progressMs)
        }
        let plainBody = lines.map { line in
            [
                String(line.startTimeMs, radix: 36),
                line.text.sanitizedForScriptTransport()
                    .truncatedForTransport(maxLength: BluetoothScriptTuning.maximumLineTextLength),
            ].joined(separator: "\t")
        }.joined(separator: "\n")
        let packedBody = plainBody.packedForScriptTransport()
        return LyricsScriptSnapshot(
            sessionState: sessionState,
            mediaKey: mediaKey,
            revision: revision,
            trackTitle: trackTitle.truncatedForTransport(maxLength: 48),
            artistName: artistName.truncatedForTransport(maxLength: 48),
            provider: provider.truncatedForTransport(maxLength: 24),
            progressMs: progressMs,
            capturedAtEpochMs: glassesTimelineCapturedAtEpochMs,
            currentLineIndex: resolvedIndex,
            encoding: packedBody.encoding,
            body: packedBody.body
        )
    }

    var bluetoothSnapshotComparable: LyricsSnapshot {
        copy(progressMs: 0, capturedAtEpochMs: 0, currentLineIndex: -1)
    }

    var bluetoothSync: LyricsPlaybackSync {
        LyricsPlaybackSync(
            sessionState: sessionState,
            mediaKey: mediaKey,
            revision: revision,
            progressMs: progressMs,
            capturedAtEpochMs: glassesTimelineCapturedAtEpochMs,
            currentLineIndex: currentLineIndex
        )
    }
}

private enum PlaybackSource {
    case manual
    case spotify
}

private enum Keys {
    static let musixmatchEmail = "musixmatch.email"
    static let musixmatchPassword = "musixmatch.password"
    static let spotifyLyricsInput = "spotifyLyrics.input"
    static let spotifyLyricsMode = "spotifyLyrics.mode"
    static let spotifyLyricsBackendURL = "spotifyLyrics.backendURL"
    static let spotifySpDcAccount = "spotify.sp_dc"
    static let snapshotRevision = "runtime.snapshotRevision"
}

private extension Int64 {
    func coerceAtLeast(_ minimum: Int64) -> Int64 {
        Swift.max(self, minimum)
    }
}

private extension String {
    func truncatedForTransport(maxLength: Int) -> String {
        guard count > maxLength else { return self }
        return String(prefix(maxLength))
    }

    func sanitizedForScriptTransport() -> String {
        replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    func packedForScriptTransport() -> (encoding: String, body: String) {
        guard let data = data(using: .utf8),
              let compressed = data.zlibCompressed()
        else {
            return (LyricsScriptSnapshot.plainEncoding, self)
        }
        let base64 = compressed.base64EncodedString()
        guard base64.count + LyricsScriptSnapshot.zlibBase64Encoding.count < count else {
            return (LyricsScriptSnapshot.plainEncoding, self)
        }
        return (LyricsScriptSnapshot.zlibBase64Encoding, base64)
    }
}

private extension Data {
    func zlibCompressed() -> Data? {
        guard !isEmpty else { return Data() }
        return withUnsafeBytes { sourceBuffer in
            guard let sourcePointer = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var outputSize = count + 128
            while outputSize <= Swift.max(count * 4, count + 4096) {
                var output = Data(count: outputSize)
                let encodedSize = output.withUnsafeMutableBytes { outputBuffer in
                    compression_encode_buffer(
                        outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        outputSize,
                        sourcePointer,
                        count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
                if encodedSize > 0 {
                    output.count = encodedSize
                    return output
                }
                outputSize *= 2
            }
            return nil
        }
    }
}

private extension LyricsSnapshot {
    func copy(
        sessionState: LyricsSessionState? = nil,
        mediaKey: String? = nil,
        revision: Int64? = nil,
        trackTitle: String? = nil,
        artistName: String? = nil,
        albumName: String? = nil,
        durationSeconds: Int? = nil,
        clearDuration: Bool = false,
        provider: String? = nil,
        sourceSummary: String? = nil,
        synced: Bool? = nil,
        progressMs: Int64? = nil,
        capturedAtEpochMs: Int64? = nil,
        currentLineIndex: Int? = nil,
        lines: [LyricsLine]? = nil,
        plainLyrics: String? = nil,
        errorMessage: String? = nil,
        clearError: Bool = false
    ) -> LyricsSnapshot {
        LyricsSnapshot(
            sessionState: sessionState ?? self.sessionState,
            mediaKey: mediaKey ?? self.mediaKey,
            revision: revision ?? self.revision,
            trackTitle: trackTitle ?? self.trackTitle,
            artistName: artistName ?? self.artistName,
            albumName: albumName ?? self.albumName,
            durationSeconds: clearDuration ? nil : (durationSeconds ?? self.durationSeconds),
            provider: provider ?? self.provider,
            sourceSummary: sourceSummary ?? self.sourceSummary,
            synced: synced ?? self.synced,
            progressMs: progressMs ?? self.progressMs,
            capturedAtEpochMs: capturedAtEpochMs ?? self.capturedAtEpochMs,
            currentLineIndex: currentLineIndex ?? self.currentLineIndex,
            lines: lines ?? self.lines,
            plainLyrics: plainLyrics ?? self.plainLyrics,
            errorMessage: clearError ? nil : (errorMessage ?? self.errorMessage)
        )
    }
}

/// Plays continuous silence through a mixable audio session so iOS keeps the app running in
/// the background. Without this, the OS suspends the app ~30s after it leaves the foreground
/// and the Spotify poll loop stops, so an off-app track change is never detected until the
/// user reopens the app. `.mixWithOthers` guarantees we never duck or interrupt the music.
@MainActor
final class BackgroundAudioKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var configured = false
    private var active = false

    /// Idempotent; safe to call every tick. Revives the session if iOS tore it down after an
    /// interruption (e.g. a phone call), since the per-tick caller keeps requesting `active`.
    func update(active shouldBeActive: Bool) {
        if shouldBeActive {
            if !active || !engine.isRunning || !player.isPlaying { start() }
        } else {
            stop()
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        configured = true
    }

    private func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            configureIfNeeded()
            if !engine.isRunning { try engine.start() }
        } catch {
            print("[RokidLyricsKeepAlive] start failed: \(error.localizedDescription)")
            return
        }
        if !player.isPlaying {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410) else { return }
            buffer.frameLength = buffer.frameCapacity // zero-filled samples == silence
            player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
            player.play()
        }
        if !active { print("[RokidLyricsKeepAlive] background audio keep-alive ON") }
        active = true
    }

    private func stop() {
        guard active else { return }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        active = false
        print("[RokidLyricsKeepAlive] background audio keep-alive OFF")
    }
}
