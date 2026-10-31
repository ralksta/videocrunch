import Foundation
@testable import VideoCrunch

/// A scan.py candidate, with only what a test cares about spelled out.
func candidate(_ path: String, sizeMB: Double = 100, savedPct: Double = 40,
               savedPct1080: Double? = nil, duration: Double? = 60,
               recommended: Bool? = true, recommended1080: Bool? = false,
               halfFPSFactor: Double? = nil) -> Candidate {
    Candidate(file_path: path, size_mb: sizeMB, codec: "h264", width: 3840, height: 2160,
              bitrate_mbps: 40, duration_sec: duration,
              estimated_saved_mb: sizeMB * savedPct / 100, estimated_saved_pct: savedPct,
              estimated_saved_mb_1080: savedPct1080.map { sizeMB * $0 / 100 },
              estimated_saved_pct_1080: savedPct1080,
              half_fps_size_factor: halfFPSFactor,
              estimated_runtime_sec: nil, recommended: recommended,
              recommended_1080: recommended1080, advice: nil,
              confidence: "high", source: "heuristic", reason: "test")
}

func response(_ candidates: [Candidate]) -> ScanResponse {
    ScanResponse(summary: ScanSummary(total_files: candidates.count, total_estimated_saved_mb: 0,
                                      history_based: 0, parallel_workers: 2),
                 results: candidates)
}

/// A view model whose scans never start scan.py; `scans` records each request.
@MainActor
final class Harness {
    let vm = WizardViewModel()
    var scans: [(urls: [URL], adding: Bool)] = []

    init() {
        vm.scanner = { [unowned self] urls, adding in scans.append((urls, adding)) }
    }

    /// Opens `paths` and answers the scan with `results`.
    func scan(_ paths: [String], results: [Candidate]) {
        vm.open(paths.map { URL(fileURLWithPath: $0) })
        vm.scanFinished(response(results), adding: false)
    }
}
