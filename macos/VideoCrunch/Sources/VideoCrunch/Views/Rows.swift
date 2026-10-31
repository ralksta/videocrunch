import AppKit
import SwiftUI

/// One scan candidate; the whole card toggles its selection.
struct CandidateRow: View {
    let candidate: Candidate
    let selected: Bool
    let toggle: () -> Void
    let preview: () -> Void
    let hover: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])

            Button(action: preview) {
                Image(systemName: "eye")
                    .font(.body)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.6))
            .help("Vorschau (Leertaste)")
            .accessibilityLabel("Vorschau von \(candidate.filename)")
            .padding(.trailing, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected
                      ? Color.accentColor.opacity(0.08)
                      : Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
        )
        .onHover { inside in
            hovering = inside
            hover(inside)
        }
    }

    private var content: some View {
            HStack(spacing: 14) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                VideoThumbnail(url: URL(fileURLWithPath: candidate.file_path))
                VStack(alignment: .leading, spacing: 5) {
                    Text(candidate.filename)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Chip(text: candidate.codec.uppercased())
                        Chip(text: candidate.resolutionString)
                        Chip(text: String(format: "%.1f Mbit/s", candidate.bitrate_mbps))
                        if candidate.source == "history" {
                            Chip(text: "aus Verlauf", icon: "clock.arrow.circlepath", tint: .blue)
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
                    Text("\(Int(candidate.estimated_saved_pct.rounded())) % von \(candidate.sizeFormatted)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let pct1080 = candidate.estimated_saved_pct_1080 {
                        Text("mit 1080p: \(Int(pct1080.rounded())) %")
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
        case "done": return ("checkmark.circle.fill", .green, "Fertig")
        case "failed": return ("xmark.circle.fill", .red, "Fehlgeschlagen")
        case "skipped": return ("forward.circle.fill", .secondary, "Übersprungen")
        case "cancelled": return ("stop.circle.fill", .orange, "Abgebrochen")
        default: return ("film", .accentColor, "\(Int(worker.fileFraction * 100)) %")
        }
    }

    /// What the running encode is doing right now.
    private var step: String? {
        guard worker.status == "running" else { return nil }
        switch worker.phase {
        case "encode": return "Durchgang \(worker.pass) · encodiert \(worker.progress) %"
        case "check": return "Durchgang \(worker.pass) · prüft Qualität"
        default: return "Analysiert …"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: look.icon)
                    .foregroundStyle(look.tint)
                Text(worker.file.isEmpty ? "Encoder \(worker.id) startet …" : worker.file)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if worker.status == "running" && worker.q > 0 {
                    Chip(text: "Q \(worker.q)")
                        .help("Qualitätsstufe, die gerade ausprobiert wird")
                }
                Text(look.label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(worker.status == "running" ? Color.primary : look.tint)
                    .monospacedDigit()
            }
            ProgressView(value: worker.fileFraction)
                .tint(look.tint)
            if let step {
                Text(step)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(12)
        .cardBackground()
    }
}

/// One file's outcome from batch.py's report.
struct ResultRow: View {
    let result: BatchItemResult
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

    private var detail: String {
        if result.status == "success" {
            var parts: [String] = []
            if let pct = result.saved_pct { parts.append("−\(Int(pct.rounded())) %") }
            if let ssim = result.ssim { parts.append(String(format: "SSIM %.3f", ssim)) }
            if let q = result.quality { parts.append("Q \(q)") }
            return parts.joined(separator: " · ")
        }
        switch result.status {
        case "cancelled": return "Abgebrochen, bevor es fertig war"
        case "skipped": return result.reason ?? "Übersprungen"
        default: return result.reason ?? "Fehlgeschlagen"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: look.icon)
                .font(.title3)
                .foregroundStyle(look.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.filename ?? "Unbekannte Datei")
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
                    Label("Vergleichen", systemImage: "rectangle.split.2x1")
                }
                .controlSize(.small)
                .help("Original und Ergebnis nebeneinander ansehen")
            }
            if result.status == "success", let bytes = result.saved_bytes {
                Text("−\(formatBytes(bytes))")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.savings)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// What the encode could not keep: said here, not left to be discovered.
    @ViewBuilder
    private var losses: some View {
        if let dv = result.dolby_vision, let kept = dv.kept_as {
            Label("Dolby Vision \(dv.profile) → \(kept)-HDR (ohne dynamische Metadaten)",
                  systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
        if let dropped = result.dropped, !dropped.isEmpty {
            Label("Nicht alle Spuren übernommen", systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help(dropped.joined(separator: "\n"))
        }
    }
}
