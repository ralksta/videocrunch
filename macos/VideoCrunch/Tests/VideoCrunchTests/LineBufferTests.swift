import XCTest
@testable import VideoCrunch

/// Pipe chunks into lines: a read can stop anywhere, also inside a character.
final class LineBufferTests: XCTestCase {
    func testALineSplitAcrossReadsComesOutWhole() {
        let buffer = LineBuffer()
        XCTAssertEqual(buffer.lines(after: Data("{\"event\": \"st".utf8)), [])
        XCTAssertEqual(buffer.lines(after: Data("art\"}\n".utf8)), [#"{"event": "start"}"#])
    }

    func testCarriageReturnEndsALineToo() {
        XCTAssertEqual(LineBuffer().lines(after: Data("10%\r20%\n".utf8)), ["10%", "20%"])
    }

    func testAnUmlautSplitBetweenReadsSurvives() {
        let bytes = Array("Größe\n".utf8)
        let buffer = LineBuffer()
        XCTAssertEqual(buffer.lines(after: Data(bytes[..<3])), [])
        XCTAssertEqual(buffer.lines(after: Data(bytes[3...])), ["Größe"])
    }

    func testColourCodesAndBlankLinesAreDropped() {
        XCTAssertEqual(LineBuffer().lines(after: Data("\u{1B}[0;32mOK\u{1B}[0m\n   \n".utf8)), ["OK"])
    }
}
