import XCTest
@testable import VideoCrunch

/// The numbers on the options page: what the selection should save.
@MainActor
final class EstimateTests: XCTestCase {
    func testSavingFollowsTheEstimate() {
        let h = Harness()
        h.scan(["/v/a.mov", "/v/b.mov"], results: [candidate("/v/a.mov"), candidate("/v/b.mov", sizeMB: 50)])
        XCTAssertEqual(h.vm.selectedEstimatedSavedMB, 60, accuracy: 0.01)
        XCTAssertEqual(h.vm.selectedTotalAfterMB, 90, accuracy: 0.01)
    }

    func testTheDownscaleSwitchUsesThe1080pEstimate() {
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov", savedPct: 15, savedPct1080: 60)])
        XCTAssertEqual(h.vm.downscaleExtraSavedMB, 45, accuracy: 0.01)
        h.vm.scaleTo1080p = true
        XCTAssertEqual(h.vm.selectedEstimatedSavedMB, 60, accuracy: 0.01)
    }

    func testAFileWithout1080pEstimateKeepsItsOwn() {
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov", savedPct: 30, savedPct1080: nil)])
        h.vm.scaleTo1080p = true
        XCTAssertEqual(h.vm.selectedEstimatedSavedMB, 30, accuracy: 0.01)
    }

    func testTrimCountsOnlyAfterTheOptionsPageSetItUp() {
        // Before, the whole file read as saved: trimEnd was still 0.
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov", duration: 60)])
        XCTAssertFalse(h.vm.isTrimmed)
        h.vm.proceedToOptions()
        XCTAssertEqual(h.vm.trimEnd, 60)
        XCTAssertFalse(h.vm.isTrimmed)
    }

    func testATrimmedVideoIsEstimatedOnWhatIsKept() {
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov", sizeMB: 100, savedPct: 40, duration: 60)])
        h.vm.proceedToOptions()
        h.vm.trimStart = 15
        h.vm.trimEnd = 45
        XCTAssertTrue(h.vm.isTrimmed)
        // Half of the file kept, 40 % smaller: 30 MB left of 100.
        XCTAssertEqual(h.vm.selectedTotalAfterMB, 30, accuracy: 0.01)
        XCTAssertEqual(h.vm.selectedEstimatedSavedMB, 70, accuracy: 0.01)
    }

    func testSeveralVideosAreNeverTrimmed() {
        let h = Harness()
        h.scan(["/v"], results: [candidate("/v/a.mov"), candidate("/v/b.mov")])
        h.vm.proceedToOptions()
        XCTAssertNil(h.vm.trimTarget)
        XCTAssertFalse(h.vm.isTrimmed)
    }

    func testAnotherVideoStartsUntrimmed() {
        let h = Harness()
        h.scan(["/v"], results: [candidate("/v/a.mov", duration: 60), candidate("/v/b.mov", duration: 90)])
        h.vm.selectedIds = ["/v/a.mov"]
        h.vm.proceedToOptions()
        h.vm.trimStart = 10
        h.vm.backToCandidates()
        h.vm.selectedIds = ["/v/b.mov"]
        h.vm.proceedToOptions()
        XCTAssertEqual(h.vm.trimStart, 0)
        XCTAssertEqual(h.vm.trimEnd, 90)
    }
}
