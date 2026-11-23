import XCTest
@testable import VideoCrunch

final class BrandAndStatsTests: XCTestCase {
    func testParseHistoryJSONLHandlesValidAndCorruptLines() {
        let jsonl = """
        {"size_mb": 100.0, "saved_pct": 50.0}
        {corrupt json line
        {"size_mb": 200.0, "saved_pct": 25.0}
        {"size_mb": 0.0, "saved_pct": 40.0}
        {"size_mb": 50.0, "saved_pct": -10.0}
        """
        let stats = LifetimeStats.parseHistoryJSONL(jsonl)
        XCTAssertEqual(stats.encodedCount, 2)
        let expectedBytes = Int64(50.0 * 1024 * 1024) + Int64(50.0 * 1024 * 1024)
        XCTAssertEqual(stats.totalSavedBytes, expectedBytes)
    }

    func testLoadAndRecordExtraCombinesHistoryAndDefaults() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let historyURL = dir.appendingPathComponent("encode_history.jsonl")
        try "{\"size_mb\": 100.0, \"saved_pct\": 40.0}\n".write(to: historyURL, atomically: true, encoding: .utf8)

        let suite = "BrandAndStatsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        LifetimeStats.recordExtra(savedBytes: 12_500_000, count: 3, defaults: defaults)
        LifetimeStats.recordExtra(savedBytes: -500, count: 1, defaults: defaults) // ignored

        let combined = LifetimeStats.load(historyURL: historyURL, defaults: defaults)
        XCTAssertEqual(combined.encodedCount, 4)
        XCTAssertEqual(combined.totalSavedBytes, Int64(40.0 * 1024 * 1024) + 12_500_000)
    }

    @MainActor
    func testHapticsDoesNotCrashWhenHeadless() {
        Haptics.tap(.alignment)
        Haptics.tap(.levelChange)
        Haptics.tap(.generic)
    }

    func testParseRecentEntriesReturnsNewestFirstAndDeduplicatesConsecutiveDuplicates() {
        let jsonl = """
        {"file": "a.mov", "size_mb": 100.0, "saved_pct": 40.0, "ssim": 0.985, "height": 2160}
        {"file": "b.mov", "size_mb": 200.0, "saved_pct": 50.0, "ssim": 0.982, "height": 1080}
        {"file": "b.mov", "size_mb": 200.0, "saved_pct": 50.1, "ssim": 0.982, "height": 1080}
        {"file": "", "size_mb": 100.0, "saved_pct": 30.0}
        {"file": "c.mov", "size_mb": 50.0, "saved_pct": 0.0}
        {"file": "d.mov", "size_mb": 80.0, "saved_pct": 25.0, "ssim": 0.990, "height": 720}
        """
        let recent = LifetimeStats.parseRecentEntries(jsonl, limit: 3)
        XCTAssertEqual(recent.map(\.filename), ["d.mov", "b.mov", "a.mov"])
        XCTAssertEqual(recent[0].height, 720)
        XCTAssertEqual(recent[0].savedBytes, Int64(20.0 * 1024 * 1024))
    }

    @MainActor
    func testSelectionStepFilterAndSort() {
        let items = [
            makeCandidate(path: "/v/small_rec.mov", sizeMB: 50, savedMB: 20, savedPct: 40, recommended: true, tip1080: false),
            makeCandidate(path: "/v/alpha_1080.mov", sizeMB: 400, savedMB: 80, savedPct: 20, recommended: false, tip1080: true),
            makeCandidate(path: "/v/big_rec.mov", sizeMB: 300, savedMB: 180, savedPct: 60, recommended: true, tip1080: true),
        ]

        XCTAssertEqual(
            SelectionStep.visibleCandidates(from: items, filter: .all, sort: .savedMB).map(\.filename),
            ["big_rec.mov", "alpha_1080.mov", "small_rec.mov"]
        )
        XCTAssertEqual(
            SelectionStep.visibleCandidates(from: items, filter: .recommended, sort: .savedPct).map(\.filename),
            ["big_rec.mov", "small_rec.mov"]
        )
        XCTAssertEqual(
            SelectionStep.visibleCandidates(from: items, filter: .downscaleTip, sort: .size).map(\.filename),
            ["alpha_1080.mov", "big_rec.mov"]
        )
        XCTAssertEqual(
            SelectionStep.visibleCandidates(from: items, filter: .all, sort: .name).map(\.filename),
            ["alpha_1080.mov", "big_rec.mov", "small_rec.mov"]
        )
    }

    override func tearDown() {
        L10n.languageOverride = nil
        Notifier.isEnabled = true
        super.tearDown()
    }

    @MainActor
    func testPreferencesPersistAndResetLocalStats() {
        defer {
            L10n.languageOverride = nil
            Notifier.isEnabled = true
            Haptics.isEnabled = true
        }
        let suite = "BrandAndStatsTests.prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let emptyHistory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-empty-\(UUID().uuidString).jsonl")

        let vm = WizardViewModel(defaults: defaults)
        vm.appLanguage = "fr"
        vm.notificationsEnabled = false
        vm.hapticsEnabled = false

        XCTAssertEqual(L10n.languageOverride, "fr")
        XCTAssertFalse(Notifier.isEnabled)
        XCTAssertFalse(Haptics.isEnabled)

        LifetimeStats.recordExtra(savedBytes: 42_000_000, count: 2, defaults: defaults)
        let beforeReset = LifetimeStats.load(historyURL: emptyHistory, defaults: defaults)
        XCTAssertEqual(beforeReset.encodedCount, 2)
        XCTAssertEqual(beforeReset.totalSavedBytes, 42_000_000)

        vm.resetLocalStats()
        let afterReset = LifetimeStats.load(historyURL: emptyHistory, defaults: defaults)
        XCTAssertEqual(afterReset.encodedCount, 0)
        XCTAssertEqual(afterReset.totalSavedBytes, 0)

        let reloaded = WizardViewModel(defaults: defaults)
        XCTAssertEqual(reloaded.appLanguage, "fr")
        XCTAssertFalse(reloaded.notificationsEnabled)
        XCTAssertFalse(reloaded.hapticsEnabled)
    }

    @MainActor
    func testStepBackAndPrimaryInspectableURL() {
        let suite = "BrandAndStatsTests.nav.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let vm = WizardViewModel(defaults: defaults)
        XCTAssertEqual(vm.currentStep, .scanning)
        XCTAssertFalse(vm.canGoBack)
        XCTAssertNil(vm.primaryInspectableURL)

        let first = makeCandidate(path: "/v/first.mov", sizeMB: 100, savedMB: 40, savedPct: 40, recommended: true, tip1080: false)
        let second = makeCandidate(path: "/v/second.mov", sizeMB: 200, savedMB: 90, savedPct: 45, recommended: true, tip1080: false)
        vm.candidates = [first, second]
        vm.selectedIds = [first.id]
        vm.focusedCandidateId = second.id

        vm.currentStep = .options
        XCTAssertTrue(vm.canGoBack)
        XCTAssertEqual(vm.primaryInspectableURL?.path, "/v/first.mov")

        vm.goBack()
        XCTAssertEqual(vm.currentStep, .candidateSelection)
        XCTAssertEqual(vm.primaryInspectableURL?.path, "/v/second.mov")

        vm.goBack()
        XCTAssertEqual(vm.currentStep, .scanning)
        XCTAssertFalse(vm.canGoBack)
    }

    private func makeCandidate(
        path: String,
        sizeMB: Double,
        savedMB: Double,
        savedPct: Double,
        recommended: Bool,
        tip1080: Bool
    ) -> Candidate {
        Candidate(
            file_path: path,
            size_mb: sizeMB,
            codec: "hevc",
            width: 3840,
            height: 2160,
            bitrate_mbps: 50,
            duration_sec: 30,
            estimated_saved_mb: savedMB,
            estimated_saved_pct: savedPct,
            estimated_saved_mb_1080: tip1080 ? savedMB * 2 : nil,
            estimated_saved_pct_1080: tip1080 ? min(90, savedPct + 20) : nil,
            half_fps_size_factor: nil,
            estimated_runtime_sec: 10,
            recommended: recommended,
            recommended_1080: tip1080,
            advice: nil,
            confidence: "medium",
            source: "heuristic",
            reason: "HEVC · 2160p"
        )
    }
}
