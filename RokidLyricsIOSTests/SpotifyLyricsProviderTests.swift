import XCTest
@testable import RokidLyricsIOS

final class SpotifyLyricsProviderTests: XCTestCase {
    func testExtractsTrackIdFromSpotifyInputs() {
        XCTAssertEqual(
            SpotifyTrackIdentifier.extract(from: "https://open.spotify.com/track/0VjIjW4GlUZAMYd2vXMi3b?si=abc"),
            "0VjIjW4GlUZAMYd2vXMi3b"
        )
        XCTAssertEqual(
            SpotifyTrackIdentifier.extract(from: "spotify:track:0VjIjW4GlUZAMYd2vXMi3b"),
            "0VjIjW4GlUZAMYd2vXMi3b"
        )
        XCTAssertEqual(
            SpotifyTrackIdentifier.extract(from: "0VjIjW4GlUZAMYd2vXMi3b"),
            "0VjIjW4GlUZAMYd2vXMi3b"
        )
    }

    func testExtractsSpDcFromCommonCookieFormats() {
        XCTAssertEqual(SpotifySpDcCookie.extractValue(from: "AQD_token_value"), "AQD_token_value")
        XCTAssertEqual(SpotifySpDcCookie.extractValue(from: "sp_dc=AQD_token_value"), "AQD_token_value")
        XCTAssertEqual(
            SpotifySpDcCookie.extractValue(from: "Cookie: sp_key=old; sp_dc=AQD_token_value; other=1"),
            "AQD_token_value"
        )
        XCTAssertEqual(
            SpotifySpDcCookie.extractValue(from: "sp_dc\tAQD_token_value\t.spotify.com"),
            "AQD_token_value"
        )
        XCTAssertNil(SpotifySpDcCookie.extractValue(from: "sp_key=old; other=1"))
    }

    func testParsesSpotifyColorLyricsLineSyncedPayload() throws {
        let result = try SpotifyColorLyricsParser.parse(
            root: [
                "lyrics": [
                    "syncType": "LINE_SYNCED",
                    "lines": [
                        [
                            "startTimeMs": "1200",
                            "endTimeMs": "3400",
                            "words": "First Spotify line",
                            "syllables": [],
                            "transliteratedWords": [],
                        ],
                        [
                            "startTimeMs": "3500",
                            "endTimeMs": "5000",
                            "words": "Second Spotify line",
                        ],
                    ],
                ],
            ],
            trackId: "0VjIjW4GlUZAMYd2vXMi3b",
            request: LyricsLookupRequest(
                title: "Blinding Lights",
                artist: "The Weeknd",
                spotifyTrackId: "0VjIjW4GlUZAMYd2vXMi3b"
            ),
            provider: "SPOTIFY",
            sourceLabel: "Spotify color-lyrics"
        )

        XCTAssertEqual(result.provider, "SPOTIFY")
        XCTAssertTrue(result.synced)
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0].startTimeMs, 1_200)
        XCTAssertEqual(result.lines[0].endTimeMs, 3_400)
        XCTAssertEqual(result.lines[0].text, "First Spotify line")
    }

    func testRejectsSpotifyPayloadWithoutLineSync() {
        XCTAssertThrowsError(
            try SpotifyColorLyricsParser.parse(
                root: [
                    "lyrics": [
                        "syncType": "UNSYNCED",
                        "lines": [],
                    ],
                ],
                trackId: "0VjIjW4GlUZAMYd2vXMi3b",
                request: LyricsLookupRequest(title: "Track", artist: "Artist"),
                provider: "SPOTIFY",
                sourceLabel: "Spotify color-lyrics"
            )
        )
    }
}
