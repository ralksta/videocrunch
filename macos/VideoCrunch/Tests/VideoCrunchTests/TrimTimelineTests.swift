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
}
