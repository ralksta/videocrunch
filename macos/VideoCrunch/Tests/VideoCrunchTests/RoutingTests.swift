import XCTest
@testable import VideoCrunch

/// Whatever is opened — Dock, Finder, drop, ⌘O — and what the wizard does with it.
@MainActor
final class RoutingTests: XCTestCase {
    private func urls(_ paths: String...) -> [URL] { paths.map { URL(fileURLWithPath: $0) } }

    func testOpeningOnTheStartScreenScans() {
        let h = Harness()
        h.vm.open(urls("/v/a.mov"))
        XCTAssertEqual(h.scans.count, 1)
        XCTAssertFalse(h.scans[0].adding)
        XCTAssertEqual(h.vm.currentStep, .scanning)
    }

    func testOpeningDuringTheSelectionAdds() {
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov")])
        h.vm.open(urls("/v/b.mov"))
        XCTAssertEqual(h.scans.last?.adding, true)
        XCTAssertEqual(h.vm.targetURLs.count, 2)
    }

    func testOpeningDuringAnEncodeWaits() {
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov")])
        h.vm.currentStep = .encoding
        h.vm.open(urls("/v/b.mov"))
        XCTAssertEqual(h.vm.queuedURLs, urls("/v/b.mov"))
        XCTAssertEqual(h.scans.count, 1, "no scan while encoding")
    }

    func testTheSameItemTwiceIsOpenedOnce() {
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov")])
        h.vm.open(urls("/v/a.mov"))
        XCTAssertEqual(h.scans.count, 1)
    }

    func testWhatArrivesDuringAScanIsAddedAfterIt() {
        let h = Harness()
        h.vm.open(urls("/v/a.mov"))
        h.vm.open(urls("/v/b.mov"))
        XCTAssertEqual(h.scans.count, 1, "the second waits for the first scan")
        h.vm.scanFinished(response([candidate("/v/a.mov")]), adding: false)
        XCTAssertEqual(h.scans.count, 2)
        XCTAssertEqual(h.scans[1].urls, urls("/v/b.mov"))
        XCTAssertTrue(h.scans[1].adding)
    }

    func testQueuedItemsAreScannedAsANewRun() {
        let h = Harness()
        h.vm.queuedURLs = urls("/v/b.mov")
        h.vm.scanQueued()
        XCTAssertEqual(h.scans.last?.urls, urls("/v/b.mov"))
        XCTAssertEqual(h.scans.last?.adding, false)
        XCTAssertTrue(h.vm.queuedURLs.isEmpty)
    }

    func testOnlyRecommendedFilesAreTicked() {
        let h = Harness()
        h.scan(["/v"], results: [candidate("/v/a.mov"), candidate("/v/b.mov", recommended: false)])
        XCTAssertEqual(h.vm.selectedIds, ["/v/a.mov"])
    }

    func testASingleVideoIsAlwaysTicked() {
        // Opened on its own, it is meant to be worked on.
        let h = Harness()
        h.scan(["/v/b.mov"], results: [candidate("/v/b.mov", recommended: false)])
        XCTAssertEqual(h.vm.selectedIds, ["/v/b.mov"])
    }

    func testAddedFilesAreTickedWhenRecommended() {
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov")])
        h.vm.open(urls("/v/b.mov", "/v/c.mov"))
        h.vm.scanFinished(response([candidate("/v/b.mov"), candidate("/v/c.mov", recommended: false)]),
                          adding: true)
        XCTAssertEqual(h.vm.selectedIds, ["/v/a.mov", "/v/b.mov"])
    }

    func testFilesWorthItOnlyAt1080pAreOfferedAndTakenWithTheDownscale() {
        let h = Harness()
        h.scan(["/v"], results: [candidate("/v/a.mov"),
                                 candidate("/v/b.mov", savedPct1080: 60, recommended: false,
                                           recommended1080: true)])
        XCTAssertEqual(h.vm.downscaleOnlyUnselected.map(\.id), ["/v/b.mov"])
        h.vm.takeDownscaleOnly()
        XCTAssertEqual(h.vm.selectedIds, ["/v/a.mov", "/v/b.mov"])
        XCTAssertTrue(h.vm.scaleTo1080p)
    }

    func testEmpfohleneRestoresTheRecommendation() {
        let h = Harness()
        h.scan(["/v"], results: [candidate("/v/a.mov"), candidate("/v/b.mov", recommended: false)])
        h.vm.selectAll()
        h.vm.selectRecommended()
        XCTAssertEqual(h.vm.selectedIds, ["/v/a.mov"])
    }

    func testTheSoundStaysAsRecordedByDefault() {
        XCTAssertEqual(WizardViewModel().audioMode, "standard")
    }

    func testStartingOverForgetsTheRun() {
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov")])
        h.vm.scaleTo1080p = true
        h.vm.startOver()
        XCTAssertTrue(h.vm.targetURLs.isEmpty)
        XCTAssertTrue(h.vm.candidates.isEmpty)
        XCTAssertFalse(h.vm.scaleTo1080p)
        XCTAssertEqual(h.vm.currentStep, .scanning)
    }
}
