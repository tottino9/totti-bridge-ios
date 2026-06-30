import XCTest
@testable import RokidLyricsIOS

final class WireProtocolTests: XCTestCase {
    func testEncodesSnapshotEnvelopeCompatibleWithAndroidContract() throws {
        let snapshot = LyricsSnapshot(
            sessionState: .ready,
            trackTitle: "Song",
            artistName: "Artist",
            provider: "LRCLIB",
            synced: true,
            currentLineIndex: 0,
            lines: [LyricsLine(startTimeMs: 0, text: "Hello")]
        )

        let json = try WireProtocol.encodePhoneMessage(.lyrics(.snapshot(snapshot)))
        let envelope = try JSONDecoder().decode(WireEnvelope.self, from: Data(json.utf8))
        let payload = try XCTUnwrap(envelope.payloadJson)

        XCTAssertEqual(envelope.channel, "lyrics")
        XCTAssertEqual(envelope.type, "snapshot")
        XCTAssertTrue(payload.contains(#""trackTitle":"Song""#))
    }

    func testDecodesTogglePlayback() {
        let message = WireProtocol.decodeGlassesMessage(#"{"channel":"runtime","type":"toggle_playback"}"#)
        XCTAssertEqual(message, .togglePlayback)
    }

    func testDecodesMediaHint() throws {
        let hint = MediaPlaybackHint(
            title: "GIVENCHY BAG",
            artistName: "34murphy",
            albumName: "CRYSTAL PIEGE",
            durationSeconds: 148,
            progressMs: 53_722,
            capturedAtEpochMs: 1_782_770_472_571,
            isPlaying: true
        )

        let json = try WireProtocol.encodeGlassesMessage(.mediaHint(hint))

        XCTAssertEqual(WireProtocol.decodeGlassesMessage(json), .mediaHint(hint))
    }

    func testWindowAndScriptCarryCompactMediaIdentity() throws {
        let window = LyricsWindowSnapshot(
            sessionState: .playing,
            mediaKey: "spotify|track-1",
            revision: 42,
            trackTitle: "Song",
            artistName: "Artist",
            provider: "SPOTIFY",
            lines: [LyricsWindowLine(startTimeMs: 1_000, text: "Hello")]
        )
        let script = LyricsScriptSnapshot(
            sessionState: .playing,
            mediaKey: "spotify|track-1",
            revision: 42,
            trackTitle: "Song",
            artistName: "Artist",
            provider: "MUSIXMATCH",
            body: "rs\tHello"
        )

        let windowJson = try WireProtocol.encodePhoneMessage(.lyrics(.window(window)))
        let scriptJson = try WireProtocol.encodePhoneMessage(.lyrics(.script(script)))
        let windowEnvelope = try JSONDecoder().decode(WireEnvelope.self, from: Data(windowJson.utf8))
        let scriptEnvelope = try JSONDecoder().decode(WireEnvelope.self, from: Data(scriptJson.utf8))
        let windowPayload = try XCTUnwrap(windowEnvelope.payloadJson)
        let scriptPayload = try XCTUnwrap(scriptEnvelope.payloadJson)

        XCTAssertTrue(windowPayload.contains(#""m":"spotify|track-1""#))
        XCTAssertTrue(windowPayload.contains(#""r":42"#))
        XCTAssertTrue(windowPayload.contains(#""v":"SPOTIFY""#))
        XCTAssertTrue(scriptPayload.contains(#""m":"spotify|track-1""#))
        XCTAssertTrue(scriptPayload.contains(#""r":42"#))
        XCTAssertTrue(scriptPayload.contains(#""v":"MUSIXMATCH""#))
    }
}
