import XCTest
@testable import RokidLyricsIOS

final class LrcParserTests: XCTestCase {
    func testParsesTimedLines() {
        let lines = LrcParser.parseSyncedLyrics("""
        [00:12.34]First line
        [01:03.50]Second line
        """)

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].startTimeMs, 12_340)
        XCTAssertEqual(lines[0].text, "First line")
        XCTAssertEqual(lines[1].startTimeMs, 63_500)
        XCTAssertEqual(lines[1].text, "Second line")
    }

    func testProgressIndexUsesLastElapsedLine() {
        let lines = [
            LyricsLine(startTimeMs: 1_000, text: "One"),
            LyricsLine(startTimeMs: 5_000, text: "Two"),
            LyricsLine(startTimeMs: 9_000, text: "Three")
        ]

        XCTAssertEqual(LrcParser.index(for: lines, progressMs: 500), -1)
        XCTAssertEqual(LrcParser.index(for: lines, progressMs: 5_200), 1)
        XCTAssertEqual(LrcParser.index(for: lines, progressMs: 12_000), 2)
    }
}
