import XCTest
@testable import VideoCrunch

/// batch.py --events, read into the encode page's state.
final class BatchProgressTests: XCTestCase {
    private func apply(_ lines: [String]) -> BatchProgress {
        var progress = BatchProgress()
        for line in lines {
            if let event = BatchEvent.decode(line) { progress.apply(event) }
        }
        return progress
    }

    private let start = #"{"event": "file_start", "worker": 1, "file": "/v/Urlaub, Tag 1.mov", "name": "Urlaub, Tag 1.mov"}"#

    func testAFileStartsWithItsFullName() {
        let worker = apply([start]).workers[1]
        XCTAssertEqual(worker?.file, "Urlaub, Tag 1.mov")
        XCTAssertEqual(worker?.path, "/v/Urlaub, Tag 1.mov")
        XCTAssertEqual(worker?.status, "running")
    }

    func testProgressCarriesPassPhaseAndQuality() {
        let worker = apply([
            start,
            #"{"event": "progress", "worker": 1, "phase": "check", "pass": 2, "q": 55, "percent": 30}"#,
        ]).workers[1]
        XCTAssertEqual(worker?.phase, "check")
        XCTAssertEqual(worker?.pass, 2)
        XCTAssertEqual(worker?.q, 55)
        XCTAssertEqual(worker?.progress, 30)
    }

    func testOtherLinesAreNotEvents() {
        XCTAssertNil(BatchEvent.decode("Traceback (most recent call last):"))
        XCTAssertNil(BatchEvent.decode("{not json"))
    }

    func testResultsAreCountedAsBatchPyCountsThem() {
        let progress = apply([
            #"{"event": "file_done", "worker": 1, "status": "success"}"#,
            #"{"event": "file_done", "worker": 2, "status": "skipped"}"#,
            #"{"event": "file_done", "worker": 1, "status": "failed"}"#,
            #"{"event": "file_done", "worker": 2, "status": "cancelled"}"#,
        ])
        XCTAssertEqual(progress.completed, 2)
        XCTAssertEqual(progress.failed, 2)
    }

    func testTheSummaryIsFinal() {
        let progress = apply([#"{"event": "summary", "succeeded": 3, "failed": 1}"#])
        XCTAssertEqual(progress.completed, 3)
        XCTAssertEqual(progress.failed, 1)
    }

    func testAFinishedFileShowsAsDone() {
        let worker = apply([start, #"{"event": "file_done", "worker": 1, "status": "success"}"#]).workers[1]
        XCTAssertEqual(worker?.status, "done")
        XCTAssertEqual(worker?.fileFraction, 1)
    }

    /// One pass's 100 % is not the file's: the bar used to restart with every pass.
    func testFileProgressOnlyMovesForward() {
        func fraction(_ phase: String, _ pass: Int, _ percent: Int) -> Double {
            WorkerStatus(id: 1, file: "", status: "running", progress: percent, q: 65,
                         phase: phase, pass: pass).fileFraction
        }
        let steps = [fraction("prepare", 0, 0), fraction("encode", 1, 50), fraction("encode", 1, 100),
                     fraction("check", 1, 50), fraction("encode", 2, 0), fraction("check", 2, 100),
                     fraction("encode", 3, 100)]
        XCTAssertEqual(steps, steps.sorted())
        XCTAssertLessThan(steps.last!, 1, "a running file is never shown as finished")
    }

    @MainActor
    func testTheViewModelFollowsTheEvents() {
        let vm = WizardViewModel()
        vm.totalToEncode = 2
        vm.parseBatchOutput([
            start,
            #"{"event": "file_done", "worker": 1, "status": "success"}"#,
            "a warning from ffmpeg",
        ])
        XCTAssertEqual(vm.completedCount, 1)
        XCTAssertEqual(vm.overallFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(vm.logs, ["a warning from ffmpeg"], "only what is not an event is a message")
    }
}
