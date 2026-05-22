import Combine
import Foundation

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

@MainActor
final class LyricsRuntimeStore: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var durationSecondsText = ""
    @Published var spotifyClientId: String {
        didSet { spotifyClient.clientId = spotifyClientId }
    }
    @Published var spotifyMonitoringEnabled = true
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
    @Published private(set) var providerStatusLabel = "Providers: Musixmatch, Netease, LRCLIB."

    let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private let defaults: UserDefaults
    private let spotifyClient: SpotifyClient
    private let bleTransport: LyricsBleCentralTransport
    private var cancellables = Set<AnyCancellable>()
    private var playbackSource: PlaybackSource = .manual
    private var playbackBaseMs: Int64 = 0
    private var playbackStartedAt: Date?
    private var activeSpotifyPlayback: SpotifyPlayback?
    private var activeMediaKey: String?
    private var lastSpotifyPollAt: Date = .distantPast
    private var spotifyPollInFlight = false
    private var lookupTask: Task<Void, Never>?
    private var lookupGeneration = 0
    private var snapshotRevision: Int64 = 0
    private var lastSentBluetoothSnapshot: LyricsSnapshot?
    private var lastSentBluetoothSync: LyricsPlaybackSync?
    private var bleProtocolReady = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let spotifyClient = SpotifyClient(defaults: defaults)
        let bleTransport = LyricsBleCentralTransport()
        self.spotifyClient = spotifyClient
        self.bleTransport = bleTransport
        self.spotifyClientId = spotifyClient.clientId
        self.spotifyAuthStatus = spotifyClient.status
        self.musixmatchEmail = defaults.string(forKey: Keys.musixmatchEmail) ?? ""
        self.musixmatchPassword = defaults.string(forKey: Keys.musixmatchPassword) ?? ""

        spotifyClient.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.spotifyAuthStatus = status
            }
            .store(in: &cancellables)

        bleTransport.onMessage = { [weak self] message in
            self?.handleGlassesMessage(message)
        }
        bleTransport.onSubscribed = { [weak self] in
            self?.completeBleHandshake()
        }
        bleTransport.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.deviceStatus = status
                if status.connectionState != .connected {
                    self.markBleProtocolNotReady()
                }
            }
            .store(in: &cancellables)
    }

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
            return max(lastLine.startTimeMs + 10_000, 30_000)
        }
        return 30_000
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
                LyricDisplayLine(id: 0, text: "", role: .next)
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
                LyricDisplayLine(id: 0, text: "", role: .next)
            ]
        }

        let currentIndex = snapshot.currentLineIndex
        return [
            displayLine(at: currentIndex - 1, role: .previous),
            displayLine(at: currentIndex, role: .current),
            displayLine(at: currentIndex + 1, role: .next),
            displayLine(at: currentIndex + 2, role: .next)
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
        Task {
            await spotifyClient.handleOpenURL(url)
            if spotifyClient.isConnected {
                spotifyMonitoringEnabled = true
                await pollSpotify(force: true)
            }
        }
    }

    func refreshSpotifyNow() {
        Task { await pollSpotify(force: true) }
    }

    func lookup() async {
        guard canLookup else { return }
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
        if spotifyMonitoringEnabled && spotifyClient.isConnected {
            applySpotifyLiveProgress()
            if Date().timeIntervalSince(lastSpotifyPollAt) >= 2.0 {
                Task { await pollSpotify(force: false) }
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

    private func pollSpotify(force: Bool) async {
        guard spotifyMonitoringEnabled, spotifyClient.isConnected, !spotifyPollInFlight else { return }
        if !force && Date().timeIntervalSince(lastSpotifyPollAt) < 2.0 { return }

        spotifyPollInFlight = true
        lastSpotifyPollAt = Date()

        do {
            guard let playback = try await spotifyClient.fetchCurrentlyPlaying() else {
                spotifyPollInFlight = false
                handleSpotifyIdle()
                return
            }
            spotifyPollInFlight = false
            handleSpotifyPlayback(playback)
        } catch {
            spotifyPollInFlight = false
            if let spotifyError = error as? SpotifyClientError,
               case .noActivePlayback = spotifyError {
                handleSpotifyIdle()
                return
            }
            spotifyNowPlayingLabel = error.localizedDescription
            if playbackSource != .spotify {
                statusLabel = error.localizedDescription
            }
        }
    }

    private func handleSpotifyPlayback(_ playback: SpotifyPlayback) {
        let media = playback.liveSnapshot
        activeSpotifyPlayback = playback
        playbackSource = .spotify
        isPlaying = media.isPlaying
        spotifyNowPlayingLabel = "\(media.title) / \(media.artist)"
        title = media.title
        artist = media.artist
        album = media.album
        durationSecondsText = media.durationSeconds.map(String.init) ?? ""

        if activeMediaKey != media.lookupKey {
            activeMediaKey = media.lookupKey
            lookupTask?.cancel()
            lookupTask = Task { @MainActor in
                await self.performLookup(
                    request: media.lookupRequest,
                    media: media,
                    expectedMediaKey: media.lookupKey
                )
            }
        } else {
            applyMediaProgress(media)
        }
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
        snapshot = LyricsSnapshot(
            sessionState: .idle,
            revision: nextSnapshotRevision(),
            sourceSummary: "Spotify is not playing.",
            capturedAtEpochMs: nowEpochMs()
        )
        statusLabel = "Spotify is not playing."
        sendBluetoothSnapshot(force: true)
    }

    private func performLookup(
        request: LyricsLookupRequest,
        media: MediaPlaybackSnapshot?,
        expectedMediaKey: String?
    ) async {
        lookupGeneration += 1
        let generation = lookupGeneration
        let lookupMediaKey = expectedMediaKey ?? mediaKey(for: request, source: media?.source ?? "manual")
        let lookupRevision = nextSnapshotRevision()
        defer {
            if generation == lookupGeneration {
                isLookingUp = false
            }
        }
        isLookingUp = true
        let progressMs = media?.positionMs ?? 0
        let source = media?.source ?? "manual"
        statusLabel = "Querying Musixmatch, Netease, LRCLIB..."

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
        sendBluetoothSnapshot()

        let composite = CompositeLyricsProvider(providers: [
            MusixmatchLyricsProvider(credentials: musixmatchCredentials),
            NeteaseLyricsProvider(),
            LrcLibLyricsClient()
        ])
        let result = await composite.fetch(request)
        guard !Task.isCancelled, generation == lookupGeneration else { return }
        if let expectedMediaKey, activeMediaKey != expectedMediaKey {
            return
        }

        providerStatusLabel = result.attemptSummaries
            .map { "\($0.provider): \($0.outcome.rawValue)" }
            .joined(separator: " | ")
            .ifBlank("Providers: no attempts yet.")

        let lineIndex = LrcParser.index(for: result.result.lines, progressMs: progressMs)
        snapshot = LyricsSnapshot(
            sessionState: media?.isPlaying == true ? .playing : .ready,
            mediaKey: lookupMediaKey,
            revision: lookupRevision,
            trackTitle: result.result.trackTitle,
            artistName: result.result.artistName,
            albumName: result.result.albumName,
            durationSeconds: result.result.durationSeconds,
            provider: result.result.provider,
            sourceSummary: result.result.sourceSummary,
            synced: result.result.synced,
            progressMs: progressMs,
            capturedAtEpochMs: nowEpochMs(),
            currentLineIndex: lineIndex,
            lines: result.result.lines,
            plainLyrics: result.result.plainLyrics,
            errorMessage: nil
        )
        statusLabel = result.result.synced ? "Synced lyrics ready." : "Track resolved without timed lyrics."
        sendBluetoothSnapshot()
        if let media {
            applyMediaProgress(media)
        }
    }

    private var musixmatchCredentials: MusixmatchCredentials? {
        let email = musixmatchEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !musixmatchPassword.isEmpty else { return nil }
        return MusixmatchCredentials(email: email, password: musixmatchPassword)
    }

    private func applySpotifyLiveProgress() {
        guard let playback = activeSpotifyPlayback else { return }
        applyMediaProgress(playback.liveSnapshot)
    }

    private func applyMediaProgress(_ media: MediaPlaybackSnapshot) {
        guard playbackSource == .spotify else { return }
        let progressMs = media.positionMs.coerceAtLeast(0)
        isPlaying = media.isPlaying
        let state: LyricsSessionState = media.isPlaying ? .playing : .ready
        applyProgress(progressMs, state: hasLyrics ? state : snapshot.sessionState)
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
        sendBluetoothSyncIfNeeded()
    }

    private func handleGlassesMessage(_ message: GlassesToPhoneMessage) {
        switch message {
        case .hello(let hello):
            guard hello.protocolVersion == TransportConstants.protocolVersion else {
                bleTransport.send(.error("Update the phone and glasses apps to the same Lyrics protocol."), priority: true)
                return
            }
            completeBleHandshake()

        case .requestSnapshot:
            sendBluetoothSnapshot(force: true)

        case .requestStatus:
            sendBluetoothStatus()

        case .togglePlayback:
            togglePlayback()
        }
    }

    private func sendBluetoothStatus() {
        guard bleProtocolReady else { return }
        bleTransport.send(.status(deviceStatus))
    }

    private func sendBluetoothSnapshot(force: Bool = false) {
        guard bleProtocolReady else { return }
        let comparable = snapshot.bluetoothSnapshotComparable
        guard force || comparable != lastSentBluetoothSnapshot else { return }
        lastSentBluetoothSnapshot = comparable
        lastSentBluetoothSync = snapshot.bluetoothSync
        bleTransport.send(.lyrics(.snapshot(snapshot)))
    }

    private func sendBluetoothSyncIfNeeded(force: Bool = false) {
        guard bleProtocolReady else { return }
        let sync = snapshot.bluetoothSync
        guard force || shouldSendBluetoothSync(sync) else { return }
        lastSentBluetoothSync = sync
        bleTransport.send(.lyrics(.sync(sync)))
    }

    private func markBleProtocolNotReady() {
        bleProtocolReady = false
        lastSentBluetoothSnapshot = nil
        lastSentBluetoothSync = nil
        bleTransport.dropQueuedWrites()
    }

    private func completeBleHandshake() {
        bleProtocolReady = true
        lastSentBluetoothSnapshot = nil
        lastSentBluetoothSync = nil
        bleTransport.dropQueuedWrites()
        bleTransport.send(
            .helloAck(
                ProtocolHelloAck(
                    protocolVersion: TransportConstants.protocolVersion,
                    appVersion: "0.1.0",
                    capabilities: ["status", "lyrics_snapshot", "lyrics_sync", "toggle_playback", "ble_gatt"]
                )
            ),
            priority: true
        )
        sendBluetoothStatus()
        sendBluetoothSnapshot(force: true)
        sendBluetoothSyncIfNeeded(force: true)
    }

    private func shouldSendBluetoothSync(_ sync: LyricsPlaybackSync) -> Bool {
        guard let previous = lastSentBluetoothSync else { return true }
        if sync.sessionState != previous.sessionState { return true }
        if sync.currentLineIndex != previous.currentLineIndex { return true }
        if sync.sessionState != .playing { return false }
        let elapsedAtSourceMs = sync.capturedAtEpochMs - previous.capturedAtEpochMs
        if elapsedAtSourceMs <= 0 { return true }
        let progressDeltaMs = sync.progressMs - previous.progressMs
        return abs(progressDeltaMs - elapsedAtSourceMs) >= 1_500
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
        return snapshotRevision
    }

    private func mediaKey(for request: LyricsLookupRequest, source: String) -> String {
        [
            source,
            request.isrc ?? "",
            request.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            request.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            request.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            request.durationSeconds.map(String.init) ?? ""
        ].joined(separator: "|")
    }
}

private extension LyricsSnapshot {
    var bluetoothSnapshotComparable: LyricsSnapshot {
        copy(progressMs: 0, capturedAtEpochMs: 0, currentLineIndex: -1)
    }

    var bluetoothSync: LyricsPlaybackSync {
        LyricsPlaybackSync(
            sessionState: sessionState,
            mediaKey: mediaKey,
            revision: revision,
            progressMs: progressMs,
            capturedAtEpochMs: capturedAtEpochMs,
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
}

private extension Int64 {
    func coerceAtLeast(_ minimum: Int64) -> Int64 {
        Swift.max(self, minimum)
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
