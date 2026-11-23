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

    func testProgressCarriesLiveSpeedAndBitrateAndClearsOnCheckOrDone() {
        var progress = apply([
            start,
            #"{"event": "progress", "worker": 1, "phase": "encode", "pass": 1, "q": 65, "percent": 42, "speed": "4.8x", "bitrate": "6420kbits/s"}"#,
        ])
        XCTAssertEqual(progress.workers[1]?.speed, "4.8x")
        XCTAssertEqual(progress.workers[1]?.bitrate, "6420kbits/s")

        if let check = BatchEvent.decode(#"{"event": "progress", "worker": 1, "phase": "check", "pass": 1, "q": 65, "percent": 30}"#) {
            progress.apply(check)
        }
        XCTAssertNil(progress.workers[1]?.speed)
        XCTAssertNil(progress.workers[1]?.bitrate)

        if let enc2 = BatchEvent.decode(#"{"event": "progress", "worker": 1, "phase": "encode", "pass": 2, "q": 55, "percent": 10, "speed": "3.2x", "bitrate": "800kb/s"}"#) {
            progress.apply(enc2)
        }
        XCTAssertEqual(progress.workers[1]?.speed, "3.2x")
        if let done = BatchEvent.decode(#"{"event": "file_done", "worker": 1, "status": "success"}"#) {
            progress.apply(done)
        }
        XCTAssertNil(progress.workers[1]?.speed)
        XCTAssertNil(progress.workers[1]?.bitrate)
    }

    func testLiveSpeedAndBitrateFormatting() {
        XCTAssertEqual(formatLiveSpeed("4.84x"), "4.8×")
        XCTAssertEqual(formatLiveSpeed(" 12x "), "12.0×")
        XCTAssertNil(formatLiveSpeed("0x"))
        XCTAssertNil(formatLiveSpeed("N/A"))
        XCTAssertNil(formatLiveSpeed(nil))

        XCTAssertEqual(formatLiveBitrate("6420.5kbits/s"), "6.4 Mbit/s")
        XCTAssertEqual(formatLiveBitrate("691kb/s"), "691 kbit/s")
        XCTAssertEqual(formatLiveBitrate("8M"), "8.0 Mbit/s")
        XCTAssertNil(formatLiveBitrate("0kb/s"))
        XCTAssertNil(formatLiveBitrate("N/A"))
        XCTAssertNil(formatLiveBitrate(nil))
    }

    @MainActor
    func testCompletedSummaryCountsSkippedAndFormatsTrimAndMergeDetails() {
        let vm = WizardViewModel()
        vm.batchResults = [
            BatchItemResult(filename: "a.mov", path: "/v/a.mov", status: "skipped", quality: nil, ssim: nil,
                            saved_pct: nil, saved_bytes: nil, duration: 0, reason: "Output file already exists",
                            dropped: nil, dolby_vision: nil, output_path: nil),
        ]
        XCTAssertEqual(vm.skippedCount, 1)

        let copyItem = BatchItemResult(
            filename: "clip.mov", path: "/v/clip.mov", status: "success", quality: nil, ssim: 1.0,
            saved_pct: 52.3, saved_bytes: 5_000_000, duration: 1.0, reason: "Video Copy (Passthrough)",
            dropped: nil, dolby_vision: nil, output_path: "/v/clip_trim.mp4"
        )
        XCTAssertEqual(ResultRow.detailText(for: copyItem), "−52 % · Verlustfrei (Stream Copy)")

        let fullCopy = BatchItemResult(
            filename: "clip.mov", path: "/v/clip.mov", status: "success", quality: nil, ssim: 1.0,
            saved_pct: -0.2, saved_bytes: -200, duration: 1.0, reason: "Video Copy (Passthrough)",
            dropped: nil, dolby_vision: nil, output_path: "/v/clip_trim.mp4"
        )
        XCTAssertEqual(ResultRow.detailText(for: fullCopy), "Verlustfrei (Stream Copy)")

        let mergeItem = BatchItemResult(
            filename: "part1_merged.mp4", path: "/v/part1.mp4", status: "success", quality: nil, ssim: nil,
            saved_pct: 0.0, saved_bytes: 0, duration: 2.0, reason: nil,
            dropped: nil, dolby_vision: nil, output_path: "/v/part1_merged.mp4"
        )
        XCTAssertEqual(ResultRow.detailText(for: mergeItem), "Verlustfrei zusammengefügt")

        let encodeItem = BatchItemResult(
            filename: "b.mov", path: "/v/b.mov", status: "success", quality: 65, ssim: 0.985,
            saved_pct: 41.0, saved_bytes: 41_000_000, duration: 10.0, reason: nil,
            dropped: nil, dolby_vision: nil, output_path: "/v/b_opt.mp4"
        )
        XCTAssertEqual(ResultRow.detailText(for: encodeItem), "−41 % · SSIM 0.985 · Q 65")
    }

    func testDetailUpdatesAndDeduplicatesAnalysisNotesDuringPrepare() {
        let progress = apply([
            start,
            #"{"event": "progress", "worker": 1, "phase": "prepare", "pass": 0, "percent": 0, "detail": "Bitrate-Analyse · Ø 106.4 Mbit/s (VBR)"}"#,
            #"{"event": "progress", "worker": 1, "phase": "prepare", "pass": 0, "percent": 0, "detail": "Bitrate-Analyse · Ø 106.4 Mbit/s (VBR)"}"#,
            #"{"event": "progress", "worker": 1, "phase": "prepare", "pass": 0, "percent": 0, "detail": "Audio-Lautheit gemessen (-18.4 LUFS)"}"#,
            #"{"event": "progress", "worker": 1, "phase": "encode", "pass": 1, "q": 65, "percent": 15}"#,
        ])
        let worker = progress.workers[1]
        XCTAssertEqual(worker?.analysisNotes, [
            "Bitrate-Analyse · Ø 106.4 Mbit/s (VBR)",
            "Audio-Lautheit gemessen (-18.4 LUFS)",
        ])
        XCTAssertNil(worker?.detail)
    }

    func testPassResultAppendsAndUpdatesVerdictInPlace() {
        let progress = apply([
            start,
            #"{"event": "progress", "worker": 1, "phase": "encode", "pass": 1, "q": 55, "percent": 100}"#,
            #"{"event": "pass_result", "worker": 1, "pass": 1, "q": 55, "saved_pct": 68.4, "ssim": 0.9681, "metric": "SSIM", "verdict": "evaluated"}"#,
            #"{"event": "pass_result", "worker": 1, "pass": 1, "q": 55, "saved_pct": 68.4, "ssim": 0.9681, "metric": "SSIM", "verdict": "too_low"}"#,
            #"{"event": "progress", "worker": 1, "phase": "encode", "pass": 2, "q": 65, "percent": 100}"#,
            #"{"event": "pass_result", "worker": 1, "pass": 2, "q": 65, "saved_pct": 53.2, "ssim": 0.9842, "metric": "SSIM", "verdict": "early_exit"}"#,
        ])
        let history = progress.workers[1]?.passHistory ?? []
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].verdict, "too_low")
        XCTAssertEqual(history[0].q, 55)
        XCTAssertEqual(history[1].verdict, "early_exit")
        XCTAssertEqual(history[1].ssim ?? 0, 0.9842, accuracy: 0.0001)
    }

    func testFileDoneRecordsCompletedFilesAndLiveSavedBytesAcrossWorkerReuse() {
        let progress = apply([
            #"{"event": "file_start", "worker": 1, "file": "/v/first.mov", "name": "first.mov"}"#,
            #"{"event": "file_done", "worker": 1, "file": "/v/first.mov", "status": "success", "quality": 65, "ssim": 0.985, "saved_pct": 45.0, "saved_bytes": 5000000}"#,
            #"{"event": "file_start", "worker": 1, "file": "/v/second.mov", "name": "second.mov"}"#,
            #"{"event": "file_done", "worker": 1, "file": "/v/second.mov", "status": "skipped", "saved_bytes": 0}"#,
            #"{"event": "file_start", "worker": 1, "file": "/v/third.mov", "name": "third.mov"}"#,
            #"{"event": "file_done", "worker": 1, "file": "/v/third.mov", "status": "success", "saved_pct": 30.0, "saved_bytes": 3000000}"#,
        ])
        XCTAssertEqual(progress.completedFiles.count, 3)
        XCTAssertEqual(progress.completedFiles.map(\.file), ["first.mov", "second.mov", "third.mov"])
        XCTAssertEqual(progress.completedFiles[0].quality, 65)
        XCTAssertEqual(progress.liveSavedBytes, 8_000_000)
    }

    func testProgressInitializesWorkerEvenWithoutPriorFileStart() {
        let progress = apply([
            #"{"event": "progress", "worker": 1, "file": "/v/movie.mov", "phase": "encode", "pass": 1, "q": 75, "percent": 42, "speed": "6.5x", "bitrate": "4800kbits/s"}"#,
        ])
        let worker = progress.workers[1]
        XCTAssertNotNil(worker)
        XCTAssertEqual(worker?.id, 1)
        XCTAssertEqual(worker?.file, "movie.mov")
        XCTAssertEqual(worker?.path, "/v/movie.mov")
        XCTAssertEqual(worker?.phase, "encode")
        XCTAssertEqual(worker?.pass, 1)
        XCTAssertEqual(worker?.q, 75)
        XCTAssertEqual(worker?.progress, 42)
        XCTAssertEqual(worker?.speed, "6.5x")
        XCTAssertEqual(worker?.bitrate, "4800kbits/s")
    }

    func testDetailCodesLocalizeAcrossLanguages() {
        defer { L10n.languageOverride = nil }

        let events = [
            start,
            #"{"event": "progress", "worker": 1, "phase": "prepare", "pass": 0, "percent": 0, "detail": "Bitrate-Analyse · Ø 105.7 Mbit/s (VBR)", "detail_code": "bitrate_analysis", "detail_args": {"avg": "105.7 Mbit/s", "vbr": "1"}}"#,
            #"{"event": "progress", "worker": 1, "phase": "prepare", "pass": 0, "percent": 0, "detail": "Qualitäts-Vortest auf 24s-Stichprobe", "detail_code": "presearch_start", "detail_args": {"sec": "24"}}"#,
            #"{"event": "progress", "worker": 1, "phase": "prepare", "pass": 0, "percent": 0, "detail": "Vortest Q=55 · SSIM 0.985", "detail_code": "presearch_probe", "detail_args": {"q": "55", "ssim": "0.985"}}"#,
        ]

        L10n.languageOverride = "en"
        let enWorker = apply(events).workers[1]
        XCTAssertEqual(enWorker?.detailCode, "presearch_probe")
        XCTAssertEqual(enWorker?.detail, "Pre-check Q=55 · SSIM 0.985")
        XCTAssertEqual(enWorker?.analysisNotes, [
            "Bitrate analysis · avg 105.7 Mbit/s (VBR)",
            "Quality pre-check on 24s sample",
            "Pre-check Q=55 · SSIM 0.985",
        ])

        L10n.languageOverride = "de"
        let deWorker = apply(events).workers[1]
        XCTAssertEqual(deWorker?.detail, "Vortest Q=55 · SSIM 0.985")
        XCTAssertEqual(deWorker?.analysisNotes, [
            "Bitrate-Analyse · Ø 105.7 Mbit/s (VBR)",
            "Qualitäts-Vortest auf 24s-Stichprobe",
            "Vortest Q=55 · SSIM 0.985",
        ])
    }

    func testLastPassTelemetrySurvivesQualityCheckAndResetsOnNextPass() {
        var progress = apply([
            start,
            #"{"event": "progress", "worker": 1, "phase": "encode", "pass": 1, "q": 65, "percent": 68, "speed": "10.9x", "bitrate": "4957.0kbits/s"}"#,
        ])
        XCTAssertEqual(progress.workers[1]?.lastPassSpeed, "10.9x")
        XCTAssertEqual(progress.workers[1]?.lastPassBitrate, "4957.0kbits/s")

        if let check = BatchEvent.decode(#"{"event": "progress", "worker": 1, "phase": "check", "pass": 1, "q": 65, "percent": 40}"#) {
            progress.apply(check)
        }
        XCTAssertNil(progress.workers[1]?.speed)
        XCTAssertNil(progress.workers[1]?.bitrate)
        XCTAssertEqual(progress.workers[1]?.lastPassSpeed, "10.9x")
        XCTAssertEqual(progress.workers[1]?.lastPassBitrate, "4957.0kbits/s")

        if let nextPass = BatchEvent.decode(#"{"event": "progress", "worker": 1, "phase": "encode", "pass": 2, "q": 55, "percent": 0}"#) {
            progress.apply(nextPass)
        }
        XCTAssertNil(progress.workers[1]?.lastPassSpeed)
        XCTAssertNil(progress.workers[1]?.lastPassBitrate)
    }
}
