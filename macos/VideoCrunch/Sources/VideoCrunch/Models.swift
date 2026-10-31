import Foundation
import SwiftUI

// MARK: - Models

struct Candidate: Identifiable, Codable, Hashable {
    var id: String { file_path }
    let file_path: String
    let size_mb: Double
    let codec: String
    let width: Int
    let height: Int
    let bitrate_mbps: Double
    let duration_sec: Double?
    let estimated_saved_mb: Double
    let estimated_saved_pct: Double
    /// Same file with the 1080p downscale on; nil when it is already 1080p.
    let estimated_saved_mb_1080: Double?
    let estimated_saved_pct_1080: Double?
    /// Encode time from past runs of this resolution class; nil without history.
    let estimated_runtime_sec: Double?
    /// Ticked before the user does anything; `advice` says why not.
    let recommended: Bool?
    /// Only worth it with the 1080p downscale.
    let recommended_1080: Bool?
    let advice: String?
    let confidence: String
    let source: String
    let reason: String

    var filename: String {
        URL(fileURLWithPath: file_path).lastPathComponent
    }

    /// scan.py's reason repeats codec, resolution and bitrate before " — ";
    /// the row already shows those as chips.
    var reasonDetail: String {
        reason.components(separatedBy: " — ").last ?? reason
    }

    /// "1080p" names the short side, so a vertical 1080x1920 video is 1080p.
    var resolutionString: String {
        let short = width > 0 && height > 0 ? min(width, height) : height
        return short > 0 ? "\(short)p" : "Unknown"
    }

    var sizeFormatted: String {
        formatMB(size_mb)
    }

    var savedFormatted: String {
        formatMB(estimated_saved_mb)
    }

    /// Older scan.py output has no recommendation: then everything counts.
    var isRecommended: Bool {
        recommended ?? true
    }

    var canDownscale: Bool {
        estimated_saved_mb_1080 != nil
    }
}

struct ScanSummary: Codable {
    let total_files: Int
    let total_estimated_saved_mb: Double
    let history_based: Int
    let parallel_workers: Int?
}

struct ScanResponse: Codable {
    let summary: ScanSummary
    let results: [Candidate]
}

struct WorkerStatus: Identifiable {
    let id: Int
    var file: String
    var status: String
    var progress: Int
    var q: Int
    var path: String = ""
    var phase: String = "prepare"
    var pass: Int = 0

    /// How far this file is, across its passes. A file usually takes about
    /// three (a binary search over four quality rungs), each an encode and
    /// then a quality check — so one pass's 100 % is not the file's 100 %.
    var fileFraction: Double {
        switch status {
        case "running" where phase == "gif":
            // One pass that gif.py measures in frames itself.
            return min(0.99, Double(progress) / 100)
        case "running":
            let step = Double(progress) / 100
            let within = phase == "check" ? 0.8 + 0.2 * step : (phase == "encode" ? 0.8 * step : 0)
            return min(0.95, (Double(max(pass, 1) - 1) + within) / 3)
        default:
            return 1
        }
    }
}

/// One line of `batch.py --events`.
struct BatchEvent: Decodable {
    let event: String
    let worker: Int?
    let file: String?
    let name: String?
    let status: String?
    let phase: String?
    let pass: Int?
    let q: Int?
    let percent: Int?
    let succeeded: Int?
    let failed: Int?

    static func decode(_ line: String) -> BatchEvent? {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BatchEvent.self, from: data)
    }
}

/// The live state of a batch, built from its events.
struct BatchProgress {
    var workers: [Int: WorkerStatus] = [:]
    var completed = 0
    var failed = 0

    mutating func apply(_ e: BatchEvent) {
        switch e.event {
        case "file_start":
            guard let wid = e.worker else { return }
            workers[wid] = WorkerStatus(id: wid, file: e.name ?? "", status: "running",
                                        progress: 0, q: 0, path: e.file ?? "")
        case "progress":
            guard let wid = e.worker, var w = workers[wid] else { return }
            w.phase = e.phase ?? w.phase
            w.pass = e.pass ?? w.pass
            w.progress = e.percent ?? w.progress
            if let q = e.q { w.q = q }
            workers[wid] = w
        case "file_done":
            guard let wid = e.worker else { return }
            // batch.py counts a skipped file as handled, not as a failure.
            let status = e.status ?? "failed"
            if status == "success" || status == "skipped" { completed += 1 } else { failed += 1 }
            guard var w = workers[wid] else { return }
            w.status = status == "success" ? "done" : status
            w.progress = 100
            workers[wid] = w
        case "summary":
            completed = e.succeeded ?? completed
            failed = e.failed ?? failed
        default:
            break
        }
    }
}

struct BatchItemResult: Codable, Identifiable {
    var id: String { path ?? filename ?? UUID().uuidString }
    let filename: String?
    let path: String?
    let status: String?
    let quality: Int?
    let ssim: Double?
    let saved_pct: Double?
    let saved_bytes: Int64?
    let duration: Double?
    let reason: String?
    /// Source tracks that could not come along, as videocrunch named them.
    let dropped: [String]?
    let dolby_vision: DolbyVision?
    /// Where the encode landed (for the before/after comparison).
    let output_path: String?
}

/// A Dolby Vision source and the HDR format its re-encode keeps.
struct DolbyVision: Codable {
    let profile: String
    let kept_as: String?
}

/// What videocrunch.py --preview wrote to preview.json.
enum OutputMode: Hashable {
    case video, gif
}

/// `gif.py --estimate`: the expected GIF, from a short sample.
struct GifEstimate: Codable, Equatable {
    let estimated_bytes: Int64
    let width: Int
    let height: Int
    let frames: Int
    let encoder: String
}

/// `gif.py --json-out`: the GIF that was made, or why not.
struct GifResult: Codable, Equatable {
    let status: String
    let output_path: String?
    let size_bytes: Int64?
    let width: Int?
    let height: Int?
    let frames: Int?
    let reason: String?
    let encoder: String?

    var isSuccess: Bool { status == "success" }
}

struct PreviewResult: Codable {
    let quality: Int
    let ssim: Double
    let meets_target: Bool
    let saved_pct: Double
    let source: String
    let preview: String
}

struct BatchReport: Codable {
    let videocrunch: Int?
    let results: [BatchItemResult]?
}

func formatMB(_ mb: Double) -> String {
    if mb >= 1024 {
        return String(format: "%.2f GB", mb / 1024.0)
    }
    return String(format: "%.1f MB", mb)
}

func formatBytes(_ bytes: Int64) -> String {
    let mb = Double(bytes) / (1024.0 * 1024.0)
    return formatMB(mb)
}
