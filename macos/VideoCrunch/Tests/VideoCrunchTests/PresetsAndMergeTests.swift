import XCTest
@testable import VideoCrunch

@MainActor
final class PresetsAndMergeTests: XCTestCase {
    private func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "VideoCrunchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    func testBuiltInPresetMatchesAndAppliesCleanly() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let vm = WizardViewModel(defaults: defaults)
        XCTAssertEqual(vm.matchingPreset?.id, "builtin.archive")

        let compact = EncodePreset.builtIn.first { $0.id == "builtin.compact1080" }!
        vm.applyPreset(compact)
        XCTAssertEqual(vm.qualityBalance, .compact)
        XCTAssertEqual(vm.scaleHeight, 1080)
        XCTAssertTrue(vm.cropBars)
        XCTAssertEqual(vm.matchingPreset?.id, "builtin.compact1080")

        vm.scaleHeight = 720
        XCTAssertNil(vm.matchingPreset)
    }

    func testCustomPresetsAndLastSettingsPersistAcrossViewModels() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let vm1 = WizardViewModel(defaults: defaults)
        vm1.targetCodec = "av1"
        vm1.qualityBalance = .high
        vm1.audioMode = "enhanced"
        vm1.cropBars = true
        vm1.saveCurrentAsPreset(name: "AV1 Hochwertig")

        XCTAssertEqual(vm1.customPresets.count, 1)
        XCTAssertEqual(vm1.matchingPreset?.name, "AV1 Hochwertig")

        let vm2 = WizardViewModel(defaults: defaults)
        XCTAssertEqual(vm2.customPresets.count, 1)
        XCTAssertEqual(vm2.targetCodec, "av1")
        XCTAssertEqual(vm2.qualityBalance, .high)
        XCTAssertEqual(vm2.audioMode, "enhanced")
        XCTAssertTrue(vm2.cropBars)

        // startOver preserves remembered settings when defaults are enabled
        vm2.startOver()
        XCTAssertEqual(vm2.targetCodec, "av1")
        XCTAssertEqual(vm2.qualityBalance, .high)

        vm2.deleteCustomPreset(id: vm2.customPresets[0].id)
        XCTAssertTrue(vm2.customPresets.isEmpty)
        vm2.resetSettingsToDefaults()
        XCTAssertEqual(vm2.targetCodec, "hevc")
        XCTAssertEqual(vm2.qualityBalance, .balanced)
    }

    func testMergeCompatibilityAndReordering() {
        let h = Harness()
        let a = candidate("/v/a.mp4", duration: 10, width: 1920, height: 1080, codec: "h264")
        let b = candidate("/v/b.mp4", duration: 20, width: 1920, height: 1080, codec: "h264")
        let diffRes = candidate("/v/c.mp4", duration: 15, width: 3840, height: 2160, codec: "h264")
        let diffCodec = candidate("/v/d.mp4", duration: 15, width: 1920, height: 1080, codec: "hevc")

        h.scan(["/v"], results: [a, b, diffRes, diffCodec])

        // Compatible pair
        h.vm.selectedIds = [a.id, b.id]
        h.vm.proceedToOptions()
        XCTAssertTrue(h.vm.canMerge)
        XCTAssertNil(h.vm.mergeIncompatibilityReason)
        h.vm.outputMode = .merge
        XCTAssertTrue(h.vm.isMerge)

        XCTAssertEqual(h.vm.orderedMergeCandidates.map(\.id), [a.id, b.id])
        h.vm.moveMergeClip(id: b.id, offset: -1)
        XCTAssertEqual(h.vm.orderedMergeCandidates.map(\.id), [b.id, a.id])

        // Changing selection to incompatible resolutions resets merge mode
        h.vm.backToCandidates()
        h.vm.selectedIds = [a.id, diffRes.id]
        h.vm.proceedToOptions()
        XCTAssertFalse(h.vm.canMerge)
        XCTAssertNotNil(h.vm.mergeIncompatibilityReason)
        XCTAssertEqual(h.vm.outputMode, .video)
        XCTAssertFalse(h.vm.isMerge)

        // Incompatible codec
        h.vm.selectedIds = [a.id, diffCodec.id]
        XCTAssertFalse(h.vm.canMerge)
        XCTAssertTrue(h.vm.mergeIncompatibilityReason?.contains("Codecs") == true)
    }
}
