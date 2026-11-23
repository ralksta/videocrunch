import XCTest
@testable import VideoCrunch

/// Frame rate, bars and sound: one switch each, sent the same way to the
/// run and its preview.
@MainActor
final class EditsTests: XCTestCase {
    func testHalvingTheRateUsesTheScanFactor() {
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov", savedPct: 40, halfFPSFactor: 0.75)])
        XCTAssertTrue(h.vm.canHalveFrameRate)
        // 100 MB -> 60 MB; at half the rate 45 MB.
        XCTAssertEqual(h.vm.halfFrameRateExtraSavedMB, 15, accuracy: 0.01)
        h.vm.halveFrameRate = true
        XCTAssertEqual(h.vm.selectedTotalAfterMB, 45, accuracy: 0.01)
    }

    func testThirtyFpsFootageHasNothingToHalve() {
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov")])
        XCTAssertFalse(h.vm.canHalveFrameRate)
        h.vm.halveFrameRate = true
        XCTAssertFalse(h.vm.editArguments.contains("--half-fps"), "not sent for nothing")
    }

    func testWithoutSoundIsOriginalAudioLeftOut() {
        let h = Harness()
        h.vm.audioMode = "none"
        XCTAssertEqual(Array(h.vm.editArguments.prefix(3)), ["--audio-mode", "standard", "--no-audio"])
    }

    func testTheSwitchesReachTheCommand() {
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov", halfFPSFactor: 0.75)])
        h.vm.halveFrameRate = true
        h.vm.cropBars = true
        h.vm.audioMode = "enhanced"
        XCTAssertEqual(h.vm.editArguments, ["--audio-mode", "enhanced", "--half-fps", "--crop-bars"])
    }

    func testUnderASizeEachFileCountsAtMostTheLimit() {
        let h = Harness()
        h.scan(["/v/a.mov", "/v/b.mov"],
               results: [candidate("/v/a.mov", sizeMB: 100), candidate("/v/b.mov", sizeMB: 8)])
        h.vm.sizeLimitMB = 25
        // 100 MB -> 25 MB; 8 MB already fits and stays.
        XCTAssertEqual(h.vm.selectedTotalAfterMB, 33, accuracy: 0.01)
    }

    func testSizeLimitPresetsAdaptToSelectedVideoSize() {
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov", sizeMB: 41.0)])
        XCTAssertTrue(h.vm.isSizeLimitUseful(10))
        XCTAssertTrue(h.vm.isSizeLimitUseful(25))
        XCTAssertFalse(h.vm.isSizeLimitUseful(50))
        XCTAssertFalse(h.vm.isSizeLimitUseful(100))

        XCTAssertFalse(h.vm.isSizeLimitMode)
        h.vm.isSizeLimitMode = true
        XCTAssertTrue(h.vm.isSizeLimitMode)
        XCTAssertEqual(h.vm.sizeLimitMB, 25)

        h.vm.isSizeLimitMode = false
        XCTAssertEqual(h.vm.sizeLimitMB, 0)
    }
}
