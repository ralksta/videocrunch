import AppKit
import SwiftUI

/// One scan candidate; the whole card toggles its selection.
struct CandidateRow: View {
    let candidate: Candidate
    let selected: Bool
    var focused: Bool = false
    let toggle: () -> Void
    let preview: () -> Void
    var inspect: (() -> Void)? = nil
    let hover: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if let inspect {
                Button(action: inspect) {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.6))
                .help(L("candidate.media_info_help"))
                .accessibilityLabel("\(L("action.media_info")): \(candidate.filename)")
            }

            Button(action: preview) {
                Image(systemName: "eye")
                    .font(.body)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.6))
            .help(L("candidate.preview_help"))
            .accessibilityLabel("\(L("action.preview")): \(candidate.filename)")
            .padding(.trailing, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected
                      ? Color.brandAccent.opacity(0.08)
                      : (focused
                         ? Color.brandTeal.opacity(0.05)
                         : Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    selected
                        ? Color.brandAccent.opacity(0.55)
                        : (focused
                           ? Color.brandTeal.opacity(0.55)
                           : (hovering ? Color.brandAccent.opacity(0.35) : Color(nsColor: .separatorColor)))
                )
        )
        .onHover { inside in
            hovering = inside
            hover(inside)
        }
        .contextMenu {
            Button {
                toggle()
            } label: {
                Label(selected ? L("selection.deselect") : L("selection.select"),
                      systemImage: selected ? "checkmark.circle" : "circle")
            }

            Divider()

            Button {
                preview()
            } label: {
                Label(L("action.preview"), systemImage: "eye")
            }

            if let inspect {
                Button {
                    inspect()
                } label: {
                    Label(L("action.media_info"), systemImage: "info.circle")
                }
            }

            Divider()

            let fileURL = URL(fileURLWithPath: candidate.file_path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Label(L("action.reveal_in_finder"), systemImage: "folder")
                }
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(candidate.file_path, forType: .string)
            } label: {
                Label(L("action.copy_path"), systemImage: "doc.on.doc")
            }
        }
    }

    private var content: some View {
        HStack(spacing: 14) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Color.brandAccent : Color.secondary.opacity(0.5))
            VideoThumbnail(url: URL(fileURLWithPath: candidate.file_path),
                           duration: candidate.duration_sec)
            VStack(alignment: .leading, spacing: 5) {
                Text(candidate.filename)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    let codecLower = candidate.codec.lowercased()
                    Chip(text: candidate.codec.uppercased(),
                         tint: (codecLower == "hevc" || codecLower == "h265" || codecLower == "av1")
                            ? .brandTeal : .secondary)
                    Chip(text: candidate.resolutionString,
                         tint: candidate.shortSide >= 2160 ? .brandAccent : .secondary)
                    Chip(text: L("unit.mbps", candidate.bitrate_mbps), monospaced: true)
                    if candidate.source == "history" {
                        Chip(text: L("candidate.from_history"), icon: "clock.arrow.circlepath", tint: .brandAccent)
                    }
                }
                if let advice = candidate.advice, !candidate.isRecommended {
                    Label(advice, systemImage: candidate.recommended_1080 == true
                          ? "arrow.down.right.and.arrow.up.left" : "lightbulb")
                        .font(.caption)
                        .foregroundStyle(candidate.recommended_1080 == true ? Color.blue : Color.secondary)
                        .lineLimit(1)
                } else {
                    Text(candidate.reasonDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 5) {
                Text("−\(candidate.savedFormatted)")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(Color.savings)
                    .monospacedDigit()
                SavingsBar(fraction: candidate.estimated_saved_pct / 100)
                    .frame(width: 90, height: 5)
                Text(L("candidate.pct_of_fmt", Int(candidate.estimated_saved_pct.rounded()), candidate.sizeFormatted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let pct1080 = candidate.estimated_saved_pct_1080 {
                    Text(L("candidate.with_1080_fmt", Int(pct1080.rounded())))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.blue)
                        .monospacedDigit()
                }
            }
        }
        .padding(12)
        .contentShape(Rectangle())
    }
}

/// One parallel encode slot.
struct WorkerRow: View {
    let worker: WorkerStatus

    private var look: (icon: String, tint: Color, label: String) {
        switch worker.status {
        case "done": return ("checkmark.circle.fill", .green, L("action.done"))
        case "failed": return ("xmark.circle.fill", .red, L("encoding.failed"))
        case "skipped": return ("forward.circle.fill", .secondary, L("encoding.skipped"))
        case "cancelled": return ("stop.circle.fill", .orange, L("encoding.cancelled"))
        default: return ("film", .brandAccent, "\(Int(worker.fileFraction * 100)) %")
        }
    }

    private var phaseIndex: Int {
        switch worker.phase {
        case "encode": return 1
        case "check": return 2
        default: return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: look.icon)
                    .foregroundStyle(look.tint)
                Text(worker.file.isEmpty ? L("worker.starting_fmt", worker.id) : worker.file)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if worker.status == "running" {
                    if let sp = formatLiveSpeed(worker.speed) {
                        Chip(text: sp, tint: .brandTeal, monospaced: true)
                    }
                    if let br = formatLiveBitrate(worker.bitrate) {
                        Chip(text: br, monospaced: true)
                    }
                    if worker.q > 0 {
                        Chip(text: L("detail.encode_q_fmt", worker.q), monospaced: true)
                            .help(L("worker.q_help"))
                    }
                }
                Text(look.label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(worker.status == "running" ? Color.primary : look.tint)
                    .monospacedDigit()
            }
            CrunchProgressBar(
                fraction: worker.fileFraction,
                active: worker.status == "running",
                indeterminate: worker.status == "running" && worker.phase == "prepare" && worker.progress == 0,
                tint: worker.status == "running" ? nil : look.tint
            )
            if worker.status == "running" {
                if worker.phase == "gif" {
                    Text("\(L("encoding.gif_running")) · \(worker.progress) %")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) {
                            phaseStep(0, label: L("encoding.analysis"))
                            phaseStep(1, label: worker.pass > 0
                                      ? L("encoding.pass_fmt", worker.pass) + " · \(worker.progress) %"
                                      : L("step.encode"))
                            phaseStep(2, label: worker.phase == "check"
                                      ? "\(L("encoding.telemetry.quality_level")) · \(worker.progress) %"
                                      : L("completed.tile.quality"))
                        }
                        .font(.caption)
                        .monospacedDigit()
                        if let detail = worker.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(12)
        .cardBackground()
    }

    private func phaseStep(_ idx: Int, label: String) -> some View {
        let isCurrent = phaseIndex == idx
        let isDone = phaseIndex > idx
        return HStack(spacing: 4) {
            Circle()
                .fill(isCurrent ? Color.brandTeal : (isDone ? Color.savings.opacity(0.7) : Color.secondary.opacity(0.3)))
                .frame(width: 5, height: 5)
            Text(label)
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .fontWeight(isCurrent ? .medium : .regular)
        }
    }
}

/// Compact selectable worker card used in Batch master-detail mode.
struct CompactWorkerRow: View {
    let worker: WorkerStatus
    let selected: Bool
    let action: () -> Void
    @State private var thumb: NSImage?

    private var statusColor: Color {
        switch worker.status {
        case "done": return .savings
        case "failed": return .red
        case "skipped": return .secondary
        case "cancelled": return .orange
        default: return .brandTeal
        }
    }

    private var statusSubtitle: String {
        switch worker.status {
        case "done": return L("action.done")
        case "failed": return L("encoding.failed")
        case "skipped": return L("encoding.skipped")
        case "cancelled": return L("encoding.cancelled")
        default:
            if worker.phase == "prepare" {
                return worker.detail ?? L("encoding.analysis_running")
            }
            if worker.phase == "check" {
                return L("encoding.check_pct_fmt", worker.progress)
            }
            if worker.phase == "gif" {
                return "GIF · \(worker.progress) %"
            }
            let passPrefix = worker.pass > 0 ? L("encoding.pass_fmt", worker.pass) : L("step.encode")
            let qSuffix = worker.q > 0 ? " · \(L("detail.encode_q_fmt", worker.q))" : ""
            return "\(passPrefix)\(qSuffix)"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.14))
                    if let thumb {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "film")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 52, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(worker.file.isEmpty ? L("worker.slot_fmt", worker.id) : worker.file)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if worker.status == "running" {
                            if worker.phase == "prepare" && worker.progress == 0 {
                                Text(L("encoding.analysis"))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Color.brandTeal)
                            } else {
                                Text("\(Int(worker.fileFraction * 100)) %")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.primary)
                                    .monospacedDigit()
                            }
                        } else {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 6, height: 6)
                        }
                    }

                    CrunchProgressBar(
                        fraction: worker.fileFraction,
                        active: worker.status == "running",
                        indeterminate: worker.status == "running" && worker.phase == "prepare" && worker.progress == 0,
                        tint: worker.status == "running" ? nil : statusColor,
                        height: 4
                    )

                    Text(statusSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected
                          ? Color.brandAccent.opacity(0.10)
                          : Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        selected
                            ? Color.brandAccent.opacity(0.65)
                            : Color(nsColor: .separatorColor).opacity(0.75),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: worker.path) {
            guard !worker.path.isEmpty,
                  FileManager.default.fileExists(atPath: worker.path) else {
                thumb = nil
                return
            }
            thumb = await VideoThumbnail.thumbnail(for: URL(fileURLWithPath: worker.path))
        }
    }
}

/// One file's outcome from batch.py's report.
struct ResultRow: View {
    let result: BatchItemResult
    /// Highlights the row in the Batch master-detail inspector.
    var selected: Bool = false
    /// Opens the before/after comparison; nil when there is nothing to compare.
    var compare: (() -> Void)? = nil

    private var look: (icon: String, tint: Color) {
        switch result.status {
        case "success": return ("checkmark.circle.fill", .green)
        case "skipped": return ("forward.circle.fill", .secondary)
        case "cancelled": return ("stop.circle.fill", .orange)
        default: return ("xmark.circle.fill", .red)
        }
    }

    static func detailText(for result: BatchItemResult) -> String {
        if result.status == "success" {
            if result.reason == "Video Copy (Passthrough)" {
                if let pct = result.saved_pct, pct > 0.5 {
                    return L("detail.lossless_saved_fmt", Int(pct.rounded()))
                }
                return L("detail.lossless")
            }
            if result.quality == nil && result.ssim == nil
                && (result.saved_bytes ?? 0) == 0
                && (result.output_path?.hasSuffix("_merged.mp4") == true) {
                return L("detail.merged")
            }
            var parts: [String] = []
            if let pct = result.saved_pct { parts.append(L("detail.encode_saved_fmt", Int(pct.rounded()))) }
            if let ssim = result.ssim { parts.append(L("detail.encode_ssim_fmt", ssim)) }
            if let q = result.quality { parts.append(L("detail.encode_q_fmt", q)) }
            return parts.joined(separator: " · ")
        }
        switch result.status {
        case "cancelled": return L("detail.cancelled")
        case "skipped": return result.reason ?? L("encoding.skipped")
        default: return result.reason ?? L("encoding.failed")
        }
    }

    private var detail: String {
        Self.detailText(for: result)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: look.icon)
                .font(.title3)
                .foregroundStyle(look.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.filename ?? L("completed.unknown_file"))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if result.status == "success" {
                    losses
                }
            }
            Spacer(minLength: 12)
            if let compare {
                Button(action: compare) {
                    Label(L("action.compare"), systemImage: "rectangle.split.2x1")
                }
                .controlSize(.small)
                .help(L("comparison.default_note"))
            } else if result.status == "success", let path = result.output_path,
                      FileManager.default.fileExists(atPath: path) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: {
                    Label(L("action.open"), systemImage: "eye")
                }
                .controlSize(.small)
            }
            if result.status == "success", let bytes = result.saved_bytes, bytes > 0 {
                Text("−\(formatBytes(bytes))")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.savings)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(selected ? Color.brandAccent.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            if let compare {
                Button(action: compare) {
                    Label(L("action.compare_before_after"), systemImage: "rectangle.split.2x1")
                }
            }
            if let path = result.output_path, FileManager.default.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(L("action.play"), systemImage: "play.fill")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label(L("action.reveal_in_finder"), systemImage: "folder")
                }
                Divider()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                } label: {
                    Label(L("action.copy_path"), systemImage: "doc.on.doc")
                }
            } else if let path = result.path {
                if FileManager.default.fileExists(atPath: path) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Label(L("action.reveal_in_finder"), systemImage: "folder")
                    }
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                } label: {
                    Label(L("action.copy_path"), systemImage: "doc.on.doc")
                }
            }
        }
    }

    /// What the encode could not keep: said here, not left to be discovered.
    @ViewBuilder
    private var losses: some View {
        if let dv = result.dolby_vision, let kept = dv.kept_as {
            Label(L("completed.dv_kept_fmt", dv.profile, kept),
                  systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
        if let dropped = result.dropped, !dropped.isEmpty {
            Label(L("completed.dropped_tracks"), systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help(dropped.joined(separator: "\n"))
        }
    }
}
