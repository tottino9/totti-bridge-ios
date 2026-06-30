import XCTest
@testable import RokidLyricsIOS

final class RuntimeHelpersTests: XCTestCase {
    func testSpotifyCallbackIsNotTreatedAsLookupDeepLink() {
        let url = URL(string: "rokidlyrics://spotify-callback?code=abc&state=xyz")!

        XCTAssertNil(LyricsRuntimeDeepLink(url: url))
    }

    func testLookupDeepLinkParsesTrackPayloadAndAllowsDuplicateQueryKeys() throws {
        let url = URL(
            string: "rokidlyrics://lookup?title=Old&title=Song&artist=Artist&album=Album&duration=180&autoplay=true&progressMs=12000"
        )!

        let deepLink = try XCTUnwrap(LyricsRuntimeDeepLink(url: url))

        XCTAssertEqual(
            deepLink,
            .lookup(
                .init(
                    title: "Song",
                    artist: "Artist",
                    album: "Album",
                    duration: "180",
                    autoplay: true,
                    progressMs: 12_000
                )
            )
        )
    }

    func testPlainLyricsTimingEstimatesLineProgressFromDuration() {
        let lines = PlainLyricsTiming.estimatedLines(
            from: """
            Alpha

            Beta
            Gamma
            """,
            durationSeconds: 12
        )

        XCTAssertEqual(
            lines,
            [
                LyricsLine(startTimeMs: 0, text: "Alpha"),
                LyricsLine(startTimeMs: 4_000, text: "Beta"),
                LyricsLine(startTimeMs: 8_000, text: "Gamma"),
            ]
        )
    }

    func testPlainLyricsTimingUsesMinimumReadableLineDuration() {
        let lines = PlainLyricsTiming.estimatedLines(
            from: """
            Alpha
            Beta
            Gamma
            """,
            durationSeconds: 3
        )

        XCTAssertEqual(lines.map(\.startTimeMs), [0, 2_500, 5_000])
    }

    func testSpotifyPlaybackSnapshotCarriesTrackIdIntoLyricsLookup() {
        let media = MediaPlaybackSnapshot(
            source: "SPOTIFY",
            trackId: "0VjIjW4GlUZAMYd2vXMi3b",
            title: "Blinding Lights",
            artist: "The Weeknd",
            album: "After Hours",
            durationSeconds: 200,
            positionMs: 42_000,
            isPlaying: true,
            isrc: "USUG11904206"
        )

        XCTAssertEqual(media.lookupRequest.spotifyTrackId, "0VjIjW4GlUZAMYd2vXMi3b")
        XCTAssertEqual(media.lookupRequest.title, "Blinding Lights")
        XCTAssertEqual(media.lookupRequest.artist, "The Weeknd")
    }

    func testLyricsSchedulerExposesPreviousCurrentAndNextLine() {
        let lines = [
            LyricsLine(startTimeMs: 1_000, endTimeMs: 2_000, text: "One"),
            LyricsLine(startTimeMs: 5_000, endTimeMs: 6_000, text: "Two"),
            LyricsLine(startTimeMs: 9_000, endTimeMs: 10_000, text: "Three"),
        ]

        let window = LyricsScheduler.window(for: lines, progressMs: 5_200)

        XCTAssertEqual(window.currentIndex, 1)
        XCTAssertEqual(window.previous?.text, "One")
        XCTAssertEqual(window.current?.text, "Two")
        XCTAssertEqual(window.next?.text, "Three")
    }

    func testTransportWindowKeepsEnoughLinesForInitialGlassesDelivery() {
        let window = LyricsTransportWindow.lineRange(
            lineCount: 40,
            anchorIndex: 10,
            maxLines: 16,
            previousLines: 1
        )

        XCTAssertEqual(window.range.lowerBound, 7)
        XCTAssertEqual(window.range.upperBound, 23)
        XCTAssertEqual(window.relativeCurrentLineIndex, 3)
    }

    func testTransportWindowFallsBackToFirstLineForInvalidAnchor() {
        let window = LyricsTransportWindow.lineRange(
            lineCount: 5,
            anchorIndex: -1,
            maxLines: 16,
            previousLines: 1
        )

        XCTAssertEqual(window.range.lowerBound, 0)
        XCTAssertEqual(window.range.upperBound, 5)
        XCTAssertEqual(window.relativeCurrentLineIndex, 0)
    }

    func testGlassesTimelinePayloadBypassesWallClockCompensationAndCarriesProvider() {
        let snapshot = LyricsSnapshot(
            sessionState: .playing,
            mediaKey: "spotify|track-1",
            revision: 9,
            trackTitle: "Song",
            artistName: "Artist",
            provider: "SPOTIFY",
            synced: true,
            progressMs: 12_345,
            capturedAtEpochMs: 1_000_000,
            currentLineIndex: 1,
            lines: [
                LyricsLine(startTimeMs: 10_000, text: "One"),
                LyricsLine(startTimeMs: 12_000, text: "Two"),
            ]
        )

        let window = snapshot.glassesTransportWindowSnapshot
        let script = snapshot.glassesTransportScriptSnapshot
        let sync = snapshot.bluetoothSync

        XCTAssertEqual(window.progressMs, snapshot.progressMs)
        XCTAssertEqual(script.progressMs, snapshot.progressMs)
        XCTAssertEqual(sync.progressMs, snapshot.progressMs)
        XCTAssertEqual(window.capturedAtEpochMs, snapshot.capturedAtEpochMs + 60_000)
        XCTAssertEqual(script.capturedAtEpochMs, snapshot.capturedAtEpochMs + 60_000)
        XCTAssertEqual(sync.capturedAtEpochMs, snapshot.capturedAtEpochMs + 60_000)
        XCTAssertEqual(window.provider, "SPOTIFY")
        XCTAssertEqual(script.provider, "SPOTIFY")
    }
}
