import XCTest
@testable import VideoCrunch

/// Trimming a few seconds out of a long video.
final class TrimTimelineTests: XCTestCase {

    func testTheLupeShowsHalfAMinuteAroundTheSelection() {
        // 2 s at 2:30 in a 5-minute video: 30 s wide, the selection centred.
        let w = TrimTimeline.zoomWindow(start: 150, end: 152, duration: 300)
        XCTAssertEqual(w.upperBound - w.lowerBound, 30, accuracy: 0.001)
        XCTAssertEqual((w.lowerBound + w.upperBound) / 2, 151, accuracy: 0.001)
    }

    func testTheLupeStaysInsideTheVideo() {
        let atStart = TrimTimeline.zoomWindow(start: 0, end: 2, duration: 300)
        XCTAssertEqual(atStart.lowerBound, 0)
        let atEnd = TrimTimeline.zoomWindow(start: 298, end: 300, duration: 300)
        XCTAssertEqual(atEnd.upperBound, 300, accuracy: 0.001)
    }

    func testALongSelectionKeepsRoomAroundIt() {
        let w = TrimTimeline.zoomWindow(start: 100, end: 140, duration: 300)
        XCTAssertEqual(w.upperBound - w.lowerBound, 120, accuracy: 0.001)
    }

    func testAShortVideoIsShownWhole() {
        let w = TrimTimeline.zoomWindow(start: 2, end: 4, duration: 11)
        XCTAssertEqual(w, 0...11)
    }

    func testTimesShowTenths() {
        XCTAssertEqual(preciseClock(2.44), "0:02.4")
        XCTAssertEqual(preciseClock(151.06), "2:31.1")
    }

    func testShiftedRangeMovesSelectionPreservingLength() {
        let moved = TrimTimeline.shiftedRange(start: 20, end: 35, delta: 12.5, duration: 100)
        XCTAssertEqual(moved.start, 32.5, accuracy: 0.001)
        XCTAssertEqual(moved.end, 47.5, accuracy: 0.001)
    }

    func testShiftedRangeClampsAtClipBoundsWithoutShrinking() {
        let atStart = TrimTimeline.shiftedRange(start: 5, end: 15, delta: -20, duration: 100)
        XCTAssertEqual(atStart.start, 0, accuracy: 0.001)
        XCTAssertEqual(atStart.end, 10, accuracy: 0.001)

        let atEnd = TrimTimeline.shiftedRange(start: 80, end: 90, delta: 30, duration: 100)
        XCTAssertEqual(atEnd.start, 90, accuracy: 0.001)
        XCTAssertEqual(atEnd.end, 100, accuracy: 0.001)

        let full = TrimTimeline.shiftedRange(start: 0, end: 100, delta: 15, duration: 100)
        XCTAssertEqual(full.start, 0, accuracy: 0.001)
        XCTAssertEqual(full.end, 100, accuracy: 0.001)
    }

    func testNudgedTimeStepsAndClamps() {
        XCTAssertEqual(TrimTimeline.nudgedTime(10.0, delta: 1.0 / 30.0, bounds: 0...60), 10.0 + 1.0 / 30.0, accuracy: 0.0001)
        XCTAssertEqual(TrimTimeline.nudgedTime(0.02, delta: -1.0, bounds: 0...60), 0, accuracy: 0.0001)
        XCTAssertEqual(TrimTimeline.nudgedTime(59.8, delta: 1.0, bounds: 0...60), 60, accuracy: 0.0001)
    }
}
