import AppKit
import SwiftUI

// MARK: - Models

struct MediaInspection: Codable, Equatable {
    let filename: String
    let path: String
    let container: String
    let size_bytes: Int64
    let duration_sec: Double
    let video: InspectedVideo
    let streams: [InspectedStream]
    let metadata: InspectedMetadata
    let warnings: InspectedWarnings
    let bitrate: InspectedBitrate

    /// Plain-text report for clipboard export.
    func plainTextSummary() -> String {
        var lines: [String] = []
        lines.append("\(filename) (\(container) · \(formatBytes(size_bytes)) · \(formatDuration(duration_sec)))")
        var videoLine = L("inspector.summary.video_fmt", video.codec.uppercased(), video.width, video.height)
        if video.fps > 0 { videoLine += L("inspector.summary.fps_fmt", String(format: "%g", video.fps)) }
        videoLine += " · \(video.hdr_label)"
        if let pix = video.pix_fmt { videoLine += " (\(pix))" }
        lines.append(videoLine)
        lines.append(L("inspector.summary.bitrate_fmt",
                       bitrate.avg_kbps, bitrate.max_kbps, bitrate.min_kbps,
                       bitrate.is_vbr ? "VBR" : "CBR"))
        if let dv = warnings.dolby_vision {
            if let kept = dv.kept_as {
                lines.append(L("inspector.summary.dv_kept_fmt", dv.profile, kept))
            } else {
                lines.append(L("inspector.summary.dv_unusable_fmt", dv.profile))
            }
        }
        for note in warnings.dropped {
            lines.append(L("inspector.summary.dropped_fmt", note))
        }
        for s in streams {
            let lang = s.language.map { " [\($0)]" } ?? ""
            let detail = s.detail.isEmpty ? "" : " — \(s.detail)"
            let state = s.kept ? L("inspector.stream.kept") : L("inspector.stream.dropped")
            lines.append(L("inspector.summary.stream_fmt", s.index, s.type, s.codec, lang, detail, state))
        }
        if let cam = metadata.camera { lines.append(L("inspector.summary.camera_fmt", cam)) }
        if let date = metadata.creation_time { lines.append(L("inspector.summary.recorded_fmt", date)) }
        if let loc = metadata.location { lines.append(L("inspector.summary.location_fmt", loc)) }
        if metadata.chapters > 0 { lines.append(L("inspector.summary.chapters_fmt", metadata.chapters)) }
        return lines.joined(separator: "\n")
    }
}

struct InspectedVideo: Codable, Equatable {
    let codec: String
    let profile: String?
    let width: Int
    let height: Int
    let fps: Double
    let pix_fmt: String?
    let bit_depth: Int
    let color_space: String?
    let color_transfer: String?
    let color_primaries: String?
    let hdr_label: String
    let is_hdr: Bool
    let rotation: Int
    let kbps: Double
}

struct InspectedStream: Codable, Equatable, Identifiable {
    var id: Int { index }
    let index: Int
    let type: String
    let codec: String
    let detail: String
    let language: String?
    let kept: Bool
}

struct InspectedMetadata: Codable, Equatable {
    let creation_time: String?
    let camera: String?
    let location: String?
    let chapters: Int
}

struct InspectedWarnings: Codable, Equatable {
    let dolby_vision: DolbyVision?
    let dropped: [String]

    var hasAny: Bool {
        dolby_vision != nil || !dropped.isEmpty
    }
}

struct InspectedBitrate: Codable, Equatable {
    let avg_kbps: Double
    let max_kbps: Double
    let min_kbps: Double
    let is_vbr: Bool
    let samples_kbps: [Double]
    let hotspots_sec: [Double]
}

// MARK: - Sheet

struct MediaInspectorSheet: View {
    let url: URL
    let inspection: MediaInspection?
    let isLoading: Bool
    let error: String?
    let onClose: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(L("inspector.loading"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                StatusHero(icon: "exclamationmark.triangle.fill", tint: .orange,
                           title: L("inspector.failed"), message: error, compact: true) {
                    EmptyView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let inspection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if inspection.warnings.hasAny {
                            warningsCard(inspection.warnings)
                        }
                        if !inspection.bitrate.samples_kbps.isEmpty {
                            bitrateCard(inspection.bitrate, duration: inspection.duration_sec)
                        }
                        streamsCard(inspection.streams)
                        if hasMetadata(inspection.metadata) {
                            metadataCard(inspection.metadata)
                        }
                    }
                    .padding(20)
                }
            }

            Divider()

            HStack {
                if let inspection {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(inspection.plainTextSummary(), forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copied = false
                        }
                    } label: {
                        Label(copied ? L("action.copied") : L("inspector.copy_text"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                Spacer()
                Button(L("action.close"), action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 540, idealWidth: 600, minHeight: 460, idealHeight: 580)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "film.stack")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(inspection?.filename ?? url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let info = inspection {
                    HStack(spacing: 6) {
                        Chip(text: info.container)
                        Chip(text: info.video.codec.uppercased())
                        if info.video.width > 0 && info.video.height > 0 {
                            Chip(text: "\(info.video.width)×\(info.video.height)")
                        }
                        if info.video.fps > 0 {
                            Chip(text: L("unit.fps_fmt", String(format: "%g", info.video.fps)))
                        }
                        Chip(text: info.video.hdr_label, tint: info.video.is_hdr ? .orange : .secondary)
                    }
                    Text("\(formatBytes(info.size_bytes)) · \(formatDuration(info.duration_sec))"
                         + (info.video.pix_fmt.map { " · \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
        }
        .padding(16)
    }

    private func warningsCard(_ warnings: InspectedWarnings) -> some View {
        OptionSection(title: L("inspector.warnings.title")) {
            VStack(alignment: .leading, spacing: 8) {
                if let dv = warnings.dolby_vision {
                    if let kept = dv.kept_as {
                        Label(L("inspector.dv_kept_fmt", dv.profile, kept),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    } else {
                        Label(L("inspector.dv_unusable_fmt", dv.profile),
                              systemImage: "xmark.octagon.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                ForEach(Array(warnings.dropped.enumerated()), id: \.offset) { _, note in
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.35))
            )
        }
    }

    private func bitrateCard(_ br: InspectedBitrate, duration: Double) -> some View {
        OptionSection(title: L("inspector.bitrate.title")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text(L("inspector.bitrate.avg_fmt", formatKbps(br.avg_kbps)))
                    Text(L("inspector.bitrate.peak_fmt", formatKbps(br.max_kbps)))
                    Text(L("inspector.bitrate.min_fmt", formatKbps(br.min_kbps)))
                    Spacer()
                    Chip(text: br.is_vbr ? "VBR" : "CBR", tint: br.is_vbr ? .blue : .secondary)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()

                BitrateSparkline(samples: br.samples_kbps, average: br.avg_kbps,
                                 hotspots: br.hotspots_sec, duration: duration)
                    .frame(height: 82)
                    .accessibilityElement()
                    .accessibilityLabel(L("inspector.bitrate.title"))
                    .accessibilityValue(L("inspector.bitrate.avg_fmt", formatKbps(br.avg_kbps)))

                if !br.hotspots_sec.isEmpty {
                    let marks = br.hotspots_sec.map { clock($0) }.joined(separator: ", ")
                    Text(L("inspector.bitrate.hotspots_fmt", marks))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .cardBackground()
        }
    }

    private func streamsCard(_ streams: [InspectedStream]) -> some View {
        OptionSection(title: L("inspector.streams_fmt", streams.count)) {
            VStack(spacing: 0) {
                ForEach(Array(streams.enumerated()), id: \.element.id) { idx, s in
                    if idx > 0 { Divider().padding(.leading, 40) }
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: s.type))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("#\(s.index) \(s.codec.uppercased())")
                                    .font(.subheadline.weight(.medium))
                                if let lang = s.language {
                                    Chip(text: lang.uppercased())
                                }
                            }
                            if !s.detail.isEmpty {
                                Text(s.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Chip(text: s.kept ? L("inspector.stream.kept") : L("inspector.stream.dropped"),
                             tint: s.kept ? .savings : .orange)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .cardBackground()
        }
    }

    private func metadataCard(_ meta: InspectedMetadata) -> some View {
        OptionSection(title: L("inspector.metadata.title")) {
            VStack(alignment: .leading, spacing: 6) {
                if let cam = meta.camera { metaRow(L("inspector.metadata.camera"), cam) }
                if let date = meta.creation_time { metaRow(L("inspector.metadata.recorded"), date) }
                if let loc = meta.location { metaRow(L("inspector.metadata.gps"), loc) }
                if meta.chapters > 0 { metaRow(L("inspector.metadata.chapters"), "\(meta.chapters)") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .cardBackground()
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    private func hasMetadata(_ m: InspectedMetadata) -> Bool {
        m.camera != nil || m.creation_time != nil || m.location != nil || m.chapters > 0
    }

    private func icon(for type: String) -> String {
        switch type {
        case "video": return "film"
        case "audio": return "speaker.wave.2"
        case "subtitle": return "captions.bubble"
        default: return "doc.text"
        }
    }

    private func formatKbps(_ kbps: Double) -> String {
        kbps >= 1000 ? L("unit.mbps", kbps / 1000.0) : L("unit.kbps", Int(kbps.rounded()))
    }
}

private struct BitrateSparkline: View {
    let samples: [Double]
    let average: Double
    let hotspots: [Double]
    let duration: Double

    var body: some View {
        Canvas { context, size in
            guard samples.count >= 2, let peak = samples.max(), peak > 0 else { return }
            let w = size.width
            let h = size.height
            let maxVal = max(peak * 1.08, 1)

            // Hotspot markers behind the curve.
            if duration > 0 {
                for spot in hotspots {
                    let x = CGFloat(min(1, max(0, spot / duration))) * w
                    var marker = Path()
                    marker.move(to: CGPoint(x: x, y: 0))
                    marker.addLine(to: CGPoint(x: x, y: h))
                    context.stroke(marker, with: .color(.orange.opacity(0.65)),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
            }

            // Average line.
            let avgY = h * (1 - CGFloat(min(1, average / maxVal)))
            var avgPath = Path()
            avgPath.move(to: CGPoint(x: 0, y: avgY))
            avgPath.addLine(to: CGPoint(x: w, y: avgY))
            context.stroke(avgPath, with: .color(.secondary.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            // Curve + area fill.
            var line = Path()
            var fill = Path()
            for (i, val) in samples.enumerated() {
                let x = w * CGFloat(i) / CGFloat(samples.count - 1)
                let y = h * (1 - CGFloat(min(1, max(0, val / maxVal))))
                let pt = CGPoint(x: x, y: y)
                if i == 0 {
                    line.move(to: pt)
                    fill.move(to: CGPoint(x: x, y: h))
                    fill.addLine(to: pt)
                } else {
                    line.addLine(to: pt)
                    fill.addLine(to: pt)
                }
            }
            fill.addLine(to: CGPoint(x: w, y: h))
            fill.closeSubpath()

            context.fill(fill, with: .linearGradient(
                Gradient(colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0.03)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: h)
            ))
            context.stroke(line, with: .color(Color.accentColor), lineWidth: 1.5)
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}
