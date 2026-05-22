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
}
