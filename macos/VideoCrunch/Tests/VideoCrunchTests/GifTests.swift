import XCTest
@testable import VideoCrunch

/// GIF mode: one video, gif.py's events and its result.
@MainActor
final class GifTests: XCTestCase {

    func testGifModeNeedsExactlyOneVideo() {
        let h = Harness()
        h.scan(["/v/a.mov", "/v/b.mov"], results: [candidate("/v/a.mov"), candidate("/v/b.mov")])
        h.vm.selectedIds = ["/v/a.mov", "/v/b.mov"]
        h.vm.outputMode = .gif
        XCTAssertFalse(h.vm.isGif, "two videos make no GIF")
        h.vm.selectedIds = ["/v/a.mov"]
        XCTAssertTrue(h.vm.isGif)
    }

    func testTheWholeVideoWithoutATrim() {
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov", duration: 12)])
        h.vm.outputMode = .gif
        XCTAssertEqual(h.vm.gifRange?.start, 0)
        XCTAssertEqual(h.vm.gifRange?.end, 12)
    }

    func testTheEstimateKeyFollowsTheSettings() {
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov", duration: 12)])
        XCTAssertEqual(h.vm.gifEstimateKey, "", "no estimate in video mode")
        h.vm.outputMode = .gif
        let before = h.vm.gifEstimateKey
        h.vm.gifWidth = 640
        XCTAssertNotEqual(h.vm.gifEstimateKey, before)
    }

    func testGifProgressIsItsOwnPercent() {
        var progress = BatchProgress()
        for line in [
            #"{"event": "file_start", "worker": 1, "file": "/v/a.mov", "name": "a.mov"}"#,
            #"{"event": "progress", "worker": 1, "file": "/v/a.mov", "phase": "gif", "percent": 40}"#,
        ] {
            if let event = BatchEvent.decode(line) { progress.apply(event) }
        }
        XCTAssertEqual(progress.workers[1]?.fileFraction ?? 0, 0.4, accuracy: 0.001)
    }

    func testTheResultIsRead() throws {
        let json = #"{"input_path": "/v/a.mov", "output_path": "/v/a.gif", "encoder": "gifski", "status": "success", "size_bytes": 2000000, "width": 480, "height": 270, "frames": 60, "duration_sec": 4.0}"#
        let result = try JSONDecoder().decode(GifResult.self, from: Data(json.utf8))
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.width, 480)
    }

    func testAFailureCarriesItsReason() throws {
        let json = #"{"input_path": "/v/a.mov", "output_path": "/v/a.gif", "encoder": "ffmpeg", "status": "failed", "reason": "kaputt"}"#
        let result = try JSONDecoder().decode(GifResult.self, from: Data(json.utf8))
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.reason, "kaputt")
    }
}
