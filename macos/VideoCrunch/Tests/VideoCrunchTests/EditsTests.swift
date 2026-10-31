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
}
