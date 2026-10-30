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
