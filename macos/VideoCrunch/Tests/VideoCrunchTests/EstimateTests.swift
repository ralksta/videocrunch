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

    func testTrimOnlyEstimatesSizeWithoutReencode() {
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov", sizeMB: 100, savedPct: 40, duration: 60)])
        h.vm.proceedToOptions()
        h.vm.trimStart = 15
        h.vm.trimEnd = 45
        h.vm.outputMode = .trimOnly
        XCTAssertTrue(h.vm.isTrimOnly)
        // Kept half the duration (30/60) with no re-encoding: exactly 50 MB left of 100 MB.
        XCTAssertEqual(h.vm.selectedTotalAfterMB, 50, accuracy: 0.01)
        XCTAssertEqual(h.vm.selectedEstimatedSavedMB, 50, accuracy: 0.01)
        XCTAssertNil(h.vm.selectedRuntimeSec)
    }

    func testQualityBalanceAdjustsTargetSSIMAndEstimatedSavings() {
        let h = Harness()
        h.scan(["/v/a.mov"], results: [candidate("/v/a.mov", sizeMB: 100, savedPct: 40)])
        XCTAssertEqual(h.vm.qualityBalance, .balanced)
        XCTAssertNil(h.vm.effectiveMinSSIM)
        XCTAssertEqual(h.vm.selectedEstimatedSavedMB, 40, accuracy: 0.01)

        h.vm.qualityBalance = .high
        XCTAssertEqual(h.vm.effectiveMinSSIM ?? 0, 0.988, accuracy: 0.0001)
        // 40% * 0.85 = 34% saved
        XCTAssertEqual(h.vm.selectedEstimatedSavedMB, 34, accuracy: 0.01)

        h.vm.qualityBalance = .compact
        XCTAssertEqual(h.vm.effectiveMinSSIM ?? 0, 0.960, accuracy: 0.0001)
        // 40% * 1.15 = 46% saved
        XCTAssertEqual(h.vm.selectedEstimatedSavedMB, 46, accuracy: 0.01)

        h.vm.minSSIMOverride = 0.950
        XCTAssertEqual(h.vm.effectiveMinSSIM ?? 0, 0.950, accuracy: 0.0001)
    }

    func testResolutionPresetsAndDownscaleEstimate() {
        let h = Harness()
        let uhd = candidate("/uhd.mp4", sizeMB: 100, savedPct: 40, savedPct1080: 60)
        h.vm.candidates = [uhd]
        h.vm.selectedIds = [uhd.id]

        XCTAssertEqual(h.vm.originalResolutionLabel, "Original (3840×2160)")
        XCTAssertFalse(h.vm.canDownscale(to: 2160))
        XCTAssertTrue(h.vm.canDownscale(to: 1440))
        XCTAssertTrue(h.vm.canDownscale(to: 1080))
        XCTAssertTrue(h.vm.canDownscale(to: 720))

        XCTAssertEqual(h.vm.selectedEstimatedSavedMB, 40, accuracy: 0.01)

        h.vm.scaleHeight = 1440
        XCTAssertEqual(h.vm.selectedEstimatedSavedMB, 53.33, accuracy: 0.05)

        h.vm.scaleHeight = 1080
        XCTAssertTrue(h.vm.scaleTo1080p)
        XCTAssertEqual(h.vm.selectedEstimatedSavedMB, 60, accuracy: 0.01)

        h.vm.scaleHeight = 720
        XCTAssertFalse(h.vm.scaleTo1080p)
        XCTAssertEqual(h.vm.selectedEstimatedSavedMB, 73.33, accuracy: 0.05)

        let second = candidate("/second.mp4", sizeMB: 50, savedPct: 40)
        h.vm.candidates = [uhd, second]
        h.vm.selectedIds = [uhd.id, second.id]
        XCTAssertEqual(h.vm.originalResolutionLabel, "Original behalten")
    }

    func testResolutionPresetLabelsFlipForPortraitSelection() {
        let h = Harness()
        let portrait = candidate("/vert.mov", width: 2160, height: 3840)
        let landscape = candidate("/horiz.mov", width: 3840, height: 2160)

        // Single portrait video: labels flip to W×H portrait dimensions
        h.vm.candidates = [portrait]
        h.vm.selectedIds = [portrait.id]
        XCTAssertTrue(h.vm.isSelectionPortrait)
        XCTAssertEqual(h.vm.originalResolutionLabel, "Original (2160×3840)")
        XCTAssertEqual(
            ResolutionPreset.all.map { h.vm.resolutionPresetLabel($0) },
            [
                "4K UHD (2160×3840)",
                "2K QHD (1440×2560)",
                "Full HD (1080×1920)",
                "HD Ready (720×1280)",
            ]
        )

        // Mixed portrait + landscape: fall back to standard landscape notation
        h.vm.candidates = [portrait, landscape]
        h.vm.selectedIds = [portrait.id, landscape.id]
        XCTAssertFalse(h.vm.isSelectionPortrait)
        XCTAssertEqual(h.vm.resolutionPresetLabel(ResolutionPreset.all[2]), "Full HD (1920×1080)")
    }
}
