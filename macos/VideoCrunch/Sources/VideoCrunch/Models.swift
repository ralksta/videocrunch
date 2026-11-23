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
    /// 48–60 fps: the result's size with the frame rate halved, as a factor; nil otherwise.
    var half_fps_size_factor: Double? = nil
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
        return short > 0 ? "\(short)p" : L("unit.resolution_unknown")
    }

    /// Short side in pixels (for portrait videos this is `width`, for landscape `height`).
    var shortSide: Int {
        width > 0 && height > 0 ? min(width, height) : max(width, height)
    }

    /// Exact dimensions as "<width>×<height>", or nil when unknown.
    var dimensionsString: String? {
        width > 0 && height > 0 ? "\(width)×\(height)" : nil
    }

    /// True when the video is vertical (portrait orientation).
    var isPortrait: Bool {
        width > 0 && height > 0 && height > width
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

struct PassAttempt: Identifiable, Equatable {
    let pass: Int
    let q: Int?
    let savedPct: Double?
    let ssim: Double?
    let metric: String?
    var verdict: String
    var note: String?

    var id: String { "\(pass)-\(q ?? -1)" }
}

struct CompletedWorkerItem: Identifiable, Equatable {
    let id: String
    let file: String
    let path: String
    let status: String
    let quality: Int?
    let ssim: Double?
    let savedPct: Double?
    let savedBytes: Int64?
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
    var speed: String? = nil
    var bitrate: String? = nil
    var lastPassSpeed: String? = nil
    var lastPassBitrate: String? = nil
    var detail: String? = nil
    var detailCode: String? = nil
    var analysisNotes: [String] = []
    var passHistory: [PassAttempt] = []

    /// How far this file is, across its passes. A file usually takes about
    /// three (a binary search over four quality rungs), each an encode and
    /// then a quality check — so one pass's 100 % is not the file's 100 %.
    var fileFraction: Double {
        switch status {
        case "running" where phase == "gif":
            // One pass that gif.py measures in frames itself.
            return min(0.99, Double(progress) / 100)
        case "running" where phase == "prepare" && pass == 0:
            return 0
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
    let quality: Int?
    let percent: Int?
    let speed: String?
    let bitrate: String?
    let detail: String?
    let detail_code: String?
    let detail_args: [String: String]?
    let saved_pct: Double?
    let saved_bytes: Int64?
    let ssim: Double?
    let metric: String?
    let verdict: String?
    let note: String?
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
    var completedFiles: [CompletedWorkerItem] = []
    var liveSavedBytes: Int64 = 0
    private var lastProbeNoteByWorker: [Int: String] = [:]

    static func localizedDetail(code: String?, args: [String: String]?, fallback: String?) -> String? {
        guard let code else { return fallback }
        switch code {
        case "bitrate_analysis":
            guard let avg = args?["avg"], !avg.isEmpty else { return fallback }
            return args?["vbr"] == "1"
                ? L("encoding.detail.bitrate_vbr_fmt", avg)
                : L("encoding.detail.bitrate_fmt", avg)
        case "audio_loudness":
            guard let lufs = args?["lufs"], !lufs.isEmpty else { return fallback }
            return L("encoding.detail.audio_loudness_fmt", lufs)
        case "hotspots":
            guard let raw = args?["count"], let count = Int(raw) else { return fallback }
            return L("encoding.detail.hotspots_fmt", count)
        case "bitrate_ladder":
            return L("encoding.detail.bitrate_ladder")
        case "presearch_start":
            guard let sec = args?["sec"], !sec.isEmpty else { return fallback }
            return L("encoding.detail.presearch_start_fmt", sec)
        case "presearch_probe":
            guard let q = args?["q"], !q.isEmpty,
                  let ssim = args?["ssim"], !ssim.isEmpty else { return fallback }
            return L("encoding.detail.presearch_probe_fmt", q, ssim)
        case "copy_mode":
            return L("encoding.detail.copy_mode")
        case "finalizing":
            return L("encoding.detail.finalizing")
        case "integrity_verified":
            return L("encoding.detail.integrity_verified")
        default:
            return fallback
        }
    }

    private func fallbackWorker(id: Int, event e: BatchEvent) -> WorkerStatus {
        let inferredName = e.file.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent }
        return WorkerStatus(
            id: id,
            file: e.name ?? inferredName ?? "",
            status: "running",
            progress: 0,
            q: 0,
            path: e.file ?? ""
        )
    }

    mutating func apply(_ e: BatchEvent) {
        switch e.event {
        case "file_start":
            guard let wid = e.worker else { return }
            lastProbeNoteByWorker[wid] = nil
            workers[wid] = WorkerStatus(id: wid, file: e.name ?? "", status: "running",
                                        progress: 0, q: 0, path: e.file ?? "")
        case "progress":
            guard let wid = e.worker else { return }
            var w = workers[wid] ?? fallbackWorker(id: wid, event: e)
            let nextPass = e.pass ?? w.pass
            if nextPass != w.pass {
                w.lastPassSpeed = nil
                w.lastPassBitrate = nil
            }
            w.phase = e.phase ?? w.phase
            w.pass = nextPass
            w.progress = e.percent ?? w.progress
            if let q = e.q { w.q = q }
            if w.phase == "encode" {
                w.speed = e.speed
                w.bitrate = e.bitrate
                if let speed = e.speed { w.lastPassSpeed = speed }
                if let bitrate = e.bitrate { w.lastPassBitrate = bitrate }
            } else {
                w.speed = nil
                w.bitrate = nil
            }
            let renderedDetail = Self.localizedDetail(code: e.detail_code, args: e.detail_args, fallback: e.detail)
            w.detail = renderedDetail
            w.detailCode = e.detail_code
            if w.phase == "prepare", let detail = renderedDetail, !detail.isEmpty {
                if e.detail_code == "presearch_probe" {
                    if let prevProbe = lastProbeNoteByWorker[wid],
                       let idx = w.analysisNotes.firstIndex(of: prevProbe) {
                        w.analysisNotes[idx] = detail
                    } else if !w.analysisNotes.contains(detail) {
                        w.analysisNotes.append(detail)
                    }
                    lastProbeNoteByWorker[wid] = detail
                } else if !w.analysisNotes.contains(detail) {
                    w.analysisNotes.append(detail)
                }
                if w.analysisNotes.count > 6 { w.analysisNotes.removeFirst() }
            }
            workers[wid] = w
        case "pass_result":
            guard let wid = e.worker else { return }
            var w = workers[wid] ?? fallbackWorker(id: wid, event: e)
            let attempt = PassAttempt(
                pass: e.pass ?? max(w.pass, 1),
                q: e.q,
                savedPct: e.saved_pct,
                ssim: e.ssim,
                metric: e.metric,
                verdict: e.verdict ?? "evaluated",
                note: e.note
            )
            if let idx = w.passHistory.firstIndex(where: { $0.id == attempt.id }) {
                w.passHistory[idx] = attempt
            } else {
                w.passHistory.append(attempt)
            }
            workers[wid] = w
        case "file_done":
            guard let wid = e.worker else { return }
            lastProbeNoteByWorker[wid] = nil
            // batch.py counts a skipped file as handled, not as a failure.
            let status = e.status ?? "failed"
            if status == "success" || status == "skipped" { completed += 1 } else { failed += 1 }
            if status == "success" {
                liveSavedBytes += max(0, e.saved_bytes ?? 0)
            }
            let existing = workers[wid]
            let filePath = e.file ?? existing?.path ?? ""
            let fileName = (existing?.file.isEmpty == false ? existing?.file : nil)
                ?? (filePath.isEmpty ? "Datei \(completedFiles.count + 1)" : URL(fileURLWithPath: filePath).lastPathComponent)
            let resolvedQuality = e.quality ?? e.q ?? ((existing?.q ?? 0) > 0 ? existing?.q : nil)
            completedFiles.append(CompletedWorkerItem(
                id: "\(completedFiles.count)-\(filePath.isEmpty ? "\(wid)" : filePath)",
                file: fileName,
                path: filePath,
                status: status,
                quality: resolvedQuality,
                ssim: e.ssim,
                savedPct: e.saved_pct,
                savedBytes: e.saved_bytes
            ))
            guard var w = existing else { return }
            w.status = status == "success" ? "done" : status
            w.progress = 100
            w.speed = nil
            w.bitrate = nil
            w.lastPassSpeed = nil
            w.lastPassBitrate = nil
            w.detail = nil
            w.detailCode = nil
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
    var output_path: String?
}

/// A Dolby Vision source and the HDR format its re-encode keeps.
struct DolbyVision: Codable, Equatable {
    let profile: String
    let kept_as: String?
}

/// What kind of output to produce for the selection.
enum OutputMode: Hashable {
    case video, trimOnly, gif, merge
}

/// A named encoding profile (built-in or user-saved) and remembered settings snapshot.
struct EncodePreset: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var isBuiltIn: Bool
    var targetCodec: String
    var qualityBalance: String
    var sizeLimitMB: Int
    var scaleHeight: Int
    var audioMode: String
    var halveFrameRate: Bool
    var cropBars: Bool
    var moveToTrash: Bool

    static var builtIn: [EncodePreset] {
        [
            EncodePreset(
                id: "builtin.archive",
                name: L("options.preset.builtin.archive"),
                isBuiltIn: true,
                targetCodec: "hevc",
                qualityBalance: QualityBalance.balanced.rawValue,
                sizeLimitMB: 0,
                scaleHeight: 0,
                audioMode: "standard",
                halveFrameRate: false,
                cropBars: false,
                moveToTrash: false
            ),
            EncodePreset(
                id: "builtin.compact1080",
                name: L("options.preset.builtin.compact1080"),
                isBuiltIn: true,
                targetCodec: "hevc",
                qualityBalance: QualityBalance.compact.rawValue,
                sizeLimitMB: 0,
                scaleHeight: 1080,
                audioMode: "standard",
                halveFrameRate: false,
                cropBars: true,
                moveToTrash: false
            ),
            EncodePreset(
                id: "builtin.mail25",
                name: L("options.preset.builtin.mail25"),
                isBuiltIn: true,
                targetCodec: "hevc",
                qualityBalance: QualityBalance.balanced.rawValue,
                sizeLimitMB: 25,
                scaleHeight: 0,
                audioMode: "standard",
                halveFrameRate: false,
                cropBars: false,
                moveToTrash: false
            ),
            EncodePreset(
                id: "builtin.highQuality",
                name: L("options.preset.builtin.high_quality"),
                isBuiltIn: true,
                targetCodec: "hevc",
                qualityBalance: QualityBalance.high.rawValue,
                sizeLimitMB: 0,
                scaleHeight: 0,
                audioMode: "standard",
                halveFrameRate: false,
                cropBars: false,
                moveToTrash: false
            ),
        ]
    }

    func matches(codec: String, balance: QualityBalance, sizeLimitMB: Int, scaleHeight: Int,
                 audioMode: String, halveFrameRate: Bool, cropBars: Bool, moveToTrash: Bool) -> Bool {
        targetCodec == codec
            && qualityBalance == balance.rawValue
            && self.sizeLimitMB == sizeLimitMB
            && self.scaleHeight == scaleHeight
            && self.audioMode == audioMode
            && self.halveFrameRate == halveFrameRate
            && self.cropBars == cropBars
            && self.moveToTrash == moveToTrash
    }
}

/// Trade-off between visual fidelity and file size reduction in quality mode.
enum QualityBalance: String, CaseIterable, Hashable {
    case high
    case balanced
    case compact

    var label: String {
        switch self {
        case .high: return L("options.balance.high")
        case .balanced: return L("options.balance.balanced")
        case .compact: return L("options.balance.compact")
        }
    }

    /// Override passed as `--min-ssim` to batch.py / videocrunch.py (nil uses default 0.980).
    var minSSIM: Double? {
        switch self {
        case .high: return 0.988
        case .balanced: return nil
        case .compact: return 0.960
        }
    }

    /// Relative multiplier applied to the heuristic savings percentage for live UI estimation.
    var savingsFactor: Double {
        switch self {
        case .high: return 0.85
        case .balanced: return 1.0
        case .compact: return 1.15
        }
    }
}

/// Standard target resolution presets keyed by short-side pixels (`--scale-height`).
struct ResolutionPreset: Identifiable, Hashable {
    let height: Int
    let name: String
    let longSide: Int
    var id: Int { height }

    func label(portrait: Bool = false) -> String {
        let dims = portrait ? "\(height)×\(longSide)" : "\(longSide)×\(height)"
        return "\(name) (\(dims))"
    }

    var label: String { label(portrait: false) }

    static let all: [ResolutionPreset] = [
        ResolutionPreset(height: 2160, name: "4K UHD", longSide: 3840),
        ResolutionPreset(height: 1440, name: "2K QHD", longSide: 2560),
        ResolutionPreset(height: 1080, name: "Full HD", longSide: 1920),
        ResolutionPreset(height: 720, name: "HD Ready", longSide: 1280),
    ]
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

func formatLiveSpeed(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard trimmed.hasSuffix("x"),
          let val = Double(trimmed.dropLast()),
          val > 0 else { return nil }
    return String(format: "%.1f×", val)
}

func formatLiveBitrate(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let kbps: Double?
    if let suffix = ["mbits/s", "mb/s", "m"].first(where: { trimmed.hasSuffix($0) }),
       let val = Double(trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) {
        kbps = val * 1000.0
    } else if let suffix = ["kbits/s", "kb/s", "k"].first(where: { trimmed.hasSuffix($0) }),
              let val = Double(trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) {
        kbps = val
    } else {
        kbps = nil
    }
    guard let kbps, kbps > 0 else { return nil }
    if kbps >= 1000 {
        return L("unit.mbps", kbps / 1000.0)
    }
    return L("unit.kbps", Int(kbps.rounded()))
}
