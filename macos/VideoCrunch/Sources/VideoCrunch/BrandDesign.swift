import AppKit
import SwiftUI

// MARK: - Brand Palette (Steel Cobalt & Glacier Teal)

extension Color {
    /// Primary interactive accent drawn from the app icon's cobalt tile.
    static let brandAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.36, green: 0.52, blue: 0.96, alpha: 1)
            : NSColor(srgbRed: 0.18, green: 0.34, blue: 0.78, alpha: 1)
    })

    /// Secondary precision accent echoing the icon's compressing chevrons,
    /// kept muted so it reads like machined anodized metal rather than neon.
    static let brandTeal = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.35, green: 0.78, blue: 0.76, alpha: 1)
            : NSColor(srgbRed: 0.08, green: 0.49, blue: 0.50, alpha: 1)
    })

    /// Thin-bar gradient shared by progress bars, savings meters and candidate bars.
    static let brandBarGradient = LinearGradient(
        colors: [.brandAccent, .brandTeal],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// MARK: - Haptics

@MainActor
enum Haptics {
    static var isEnabled = true

    static func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        guard isEnabled, NSApp != nil else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

// MARK: - Geometric Brand Mark (`> [film] <`)

/// Minimal geometric version of the VideoCrunch icon: a film frame flanked
/// by precision chevrons that squeeze inward on drop and scan cleanly.
struct CrunchMark: View {
    var size: CGFloat = 56
    var squeeze: CGFloat = 0
    var scanning: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if scanning && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.8) / 1.8
                    canvas(scanPhase: phase)
                }
            } else {
                canvas(scanPhase: nil)
            }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.74), value: squeeze)
        .accessibilityHidden(true)
    }

    private func canvas(scanPhase: Double?) -> some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let s = min(w, h)
            let clamped = min(1, max(0, squeeze))

            // Central film frame
            let frameW = s * 0.44
            let frameH = s * 0.54
            let frameRect = CGRect(
                x: (w - frameW) / 2,
                y: (h - frameH) / 2,
                width: frameW,
                height: frameH
            )
            let framePath = Path(roundedRect: frameRect, cornerRadius: s * 0.08)
            context.fill(framePath, with: .color(Color.primary.opacity(0.07)))
            context.stroke(framePath, with: .color(Color.primary.opacity(0.28)),
                           lineWidth: max(1, s * 0.024))

            // Top and bottom sprocket cutouts
            let holeW = frameW * 0.17
            let holeH = frameH * 0.12
            let topY = frameRect.minY + frameH * 0.12
            let botY = frameRect.maxY - frameH * 0.12 - holeH
            for xFrac in [0.22, 0.50, 0.78] {
                let hx = frameRect.minX + frameW * xFrac - holeW / 2
                for hy in [topY, botY] {
                    let hole = Path(roundedRect: CGRect(x: hx, y: hy, width: holeW, height: holeH),
                                    cornerRadius: s * 0.02)
                    context.fill(hole, with: .color(Color.primary.opacity(0.18)))
                }
            }

            // Inner picture window
            let innerRect = CGRect(
                x: frameRect.minX + frameW * 0.15,
                y: frameRect.minY + frameH * 0.30,
                width: frameW * 0.70,
                height: frameH * 0.40
            )
            let innerPath = Path(roundedRect: innerRect, cornerRadius: s * 0.035)
            context.stroke(innerPath, with: .color(Color.primary.opacity(0.16)),
                           lineWidth: max(0.75, s * 0.015))

            // Subtle scanning beam across the frame
            if let scanPhase {
                context.drawLayer { layer in
                    layer.clip(to: framePath)
                    let scanX = frameRect.minX + frameW * CGFloat(scanPhase)
                    var beam = Path()
                    beam.move(to: CGPoint(x: scanX, y: frameRect.minY))
                    beam.addLine(to: CGPoint(x: scanX, y: frameRect.maxY))
                    layer.stroke(beam, with: .color(Color.brandTeal.opacity(0.55)),
                                 lineWidth: max(1.2, s * 0.03))
                }
            }

            // Compressing chevrons (> left, < right)
            let gap = s * (0.14 - 0.075 * clamped)
            let chevW = s * 0.12
            let chevH = s * 0.16
            let midY = h / 2

            var leftChevron = Path()
            let leftTipX = frameRect.minX - gap
            leftChevron.move(to: CGPoint(x: leftTipX - chevW, y: midY - chevH))
            leftChevron.addLine(to: CGPoint(x: leftTipX, y: midY))
            leftChevron.addLine(to: CGPoint(x: leftTipX - chevW, y: midY + chevH))

            var rightChevron = Path()
            let rightTipX = frameRect.maxX + gap
            rightChevron.move(to: CGPoint(x: rightTipX + chevW, y: midY - chevH))
            rightChevron.addLine(to: CGPoint(x: rightTipX, y: midY))
            rightChevron.addLine(to: CGPoint(x: rightTipX + chevW, y: midY + chevH))

            let strokeStyle = StrokeStyle(
                lineWidth: max(1.8, s * 0.055),
                lineCap: .round,
                lineJoin: .round
            )
            context.stroke(leftChevron, with: .color(.brandTeal), style: strokeStyle)
            context.stroke(rightChevron, with: .color(.brandTeal), style: strokeStyle)
        }
    }
}

// MARK: - Precision Progress & Meter Bars

/// Refined capsule progress bar with brand gradient and a gentle sheen while running.
struct CrunchProgressBar: View {
    let fraction: Double
    var active: Bool = false
    var indeterminate: Bool = false
    var tint: Color? = nil
    var height: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let clamped = min(1, max(0, fraction))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(contrast == .increased ? 0.18 : 0.08))
                    .overlay {
                        if contrast == .increased {
                            Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75)
                        }
                    }

                if indeterminate && active {
                    if reduceMotion {
                        barFill
                            .opacity(0.65)
                            .frame(width: max(height * 2, geo.size.width * 0.30))
                    } else {
                        let pillW = max(28, geo.size.width * 0.30)
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                            let t = context.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: 1.6) / 1.6
                            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                            let x = -pillW + (geo.size.width + pillW) * CGFloat(eased)
                            barFill
                                .opacity(0.85)
                                .frame(width: pillW)
                                .offset(x: x)
                        }
                    }
                } else {
                    let fillWidth = max(clamped > 0 ? height : 0, geo.size.width * clamped)
                    barFill
                        .frame(width: fillWidth)
                        .overlay {
                            if active && !reduceMotion && fillWidth > 12 {
                                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                                    let t = context.date.timeIntervalSinceReferenceDate
                                        .truncatingRemainder(dividingBy: 2.2) / 2.2
                                    let bandW = max(24, fillWidth * 0.35)
                                    let x = -bandW + (fillWidth + bandW * 2) * CGFloat(t)
                                    LinearGradient(
                                        colors: [.clear, .white.opacity(0.20), .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                    .frame(width: bandW)
                                    .offset(x: x - fillWidth / 2 + bandW / 2)
                                }
                                .clipShape(Capsule())
                            }
                        }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: clamped)
        .accessibilityElement()
        .accessibilityLabel(L("a11y.progress_label"))
        .accessibilityValue(indeterminate && active ? L("a11y.progress_analyzing") : "\(Int((clamped * 100).rounded())) %")
    }

    @ViewBuilder
    private var barFill: some View {
        if let tint {
            Capsule().fill(tint)
        } else {
            Capsule().fill(Color.brandBarGradient)
        }
    }
}

/// Interactive compression meter bar with subtle boundary ticks that move with the options.
struct CrunchMeterBar: View {
    let fraction: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let clamped = min(1, max(0.05, fraction))
        GeometryReader { geo in
            let fillWidth = max(8, geo.size.width * clamped)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.brandTeal.opacity(contrast == .increased ? 0.26 : 0.16))
                    .frame(height: 7)
                Capsule()
                    .fill(Color.brandBarGradient)
                    .frame(width: fillWidth, height: 7)
                // Precision boundary notch
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.brandTeal)
                    .frame(width: 2.5, height: 11)
                    .offset(x: max(0, min(geo.size.width - 2.5, fillWidth - 1.25)))
            }
            .frame(height: 11)
        }
        .frame(height: 11)
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: clamped)
        .accessibilityElement()
        .accessibilityValue(L("a11y.size_ratio_fmt", Int((min(1, max(0, fraction)) * 100).rounded())))
    }
}

// MARK: - Lifetime Savings Stats

struct RecentEncodeEntry: Identifiable, Equatable {
    let id: String
    let filename: String
    let savedPct: Double
    let savedBytes: Int64
    let ssim: Double?
    let height: Int?
    let timestamp: String?
}

struct LifetimeStats: Equatable {
    let totalSavedBytes: Int64
    let encodedCount: Int

    private static let extraBytesKey = "videocrunch.extraSavedBytes"
    private static let extraCountKey = "videocrunch.extraRunCount"

    private struct HistoryRecord: Decodable {
        let ts: String?
        let file: String?
        let size_mb: Double?
        let saved_pct: Double?
        let ssim: Double?
        let height: Int?
    }

    static var defaultHistoryURL: URL {
        AppRuntime.logDirectoryURL().appendingPathComponent("encode_history.jsonl")
    }

    static func parseHistoryJSONL(_ text: String) -> LifetimeStats {
        let decoder = JSONDecoder()
        var totalBytes: Int64 = 0
        var count = 0
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let rec = try? decoder.decode(HistoryRecord.self, from: data),
                  let sizeMB = rec.size_mb, sizeMB > 0,
                  let savedPct = rec.saved_pct, savedPct > 0 else {
                continue
            }
            totalBytes += Int64(sizeMB * (savedPct / 100.0) * 1024.0 * 1024.0)
            count += 1
        }
        return LifetimeStats(totalSavedBytes: totalBytes, encodedCount: count)
    }

    static func parseRecentEntries(_ text: String, limit: Int = 4) -> [RecentEncodeEntry] {
        guard limit > 0 else { return [] }
        let decoder = JSONDecoder()
        var parsed: [RecentEncodeEntry] = []
        for (index, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            guard let data = line.data(using: .utf8),
                  let rec = try? decoder.decode(HistoryRecord.self, from: data),
                  let file = rec.file?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !file.isEmpty,
                  let sizeMB = rec.size_mb, sizeMB > 0,
                  let savedPct = rec.saved_pct, savedPct > 0 else {
                continue
            }
            let bytes = Int64(sizeMB * (savedPct / 100.0) * 1024.0 * 1024.0)
            parsed.append(RecentEncodeEntry(
                id: "\(index)-\(file)",
                filename: file,
                savedPct: savedPct,
                savedBytes: bytes,
                ssim: rec.ssim,
                height: rec.height,
                timestamp: rec.ts
            ))
        }

        var recent: [RecentEncodeEntry] = []
        var lastKey: String?
        for entry in parsed.reversed() {
            let key = "\(entry.filename)|\(Int(entry.savedPct.rounded()))"
            if key == lastKey { continue }
            lastKey = key
            recent.append(entry)
            if recent.count >= limit { break }
        }
        return recent
    }

    static func loadRecent(historyURL: URL? = defaultHistoryURL, limit: Int = 4) -> [RecentEncodeEntry] {
        guard let historyURL,
              let text = try? String(contentsOf: historyURL, encoding: .utf8) else {
            return []
        }
        return parseRecentEntries(text, limit: limit)
    }

    static func load(historyURL: URL? = defaultHistoryURL, defaults: UserDefaults? = nil) -> LifetimeStats {
        var totalBytes: Int64 = 0
        var count = 0
        if let historyURL,
           let text = try? String(contentsOf: historyURL, encoding: .utf8) {
            let parsed = parseHistoryJSONL(text)
            totalBytes += parsed.totalSavedBytes
            count += parsed.encodedCount
        }
        if let defaults {
            let extraBytes = (defaults.object(forKey: extraBytesKey) as? NSNumber)?.int64Value ?? 0
            let extraCount = defaults.integer(forKey: extraCountKey)
            totalBytes += max(0, extraBytes)
            count += max(0, extraCount)
        }
        return LifetimeStats(totalSavedBytes: totalBytes, encodedCount: count)
    }

    static func recordExtra(savedBytes: Int64, count: Int, defaults: UserDefaults?) {
        guard let defaults, savedBytes > 0, count > 0 else { return }
        let currentBytes = (defaults.object(forKey: extraBytesKey) as? NSNumber)?.int64Value ?? 0
        let currentCount = defaults.integer(forKey: extraCountKey)
        defaults.set(currentBytes + savedBytes, forKey: extraBytesKey)
        defaults.set(currentCount + count, forKey: extraCountKey)
    }

    static func resetExtra(defaults: UserDefaults?) {
        guard let defaults else { return }
        defaults.removeObject(forKey: extraBytesKey)
        defaults.removeObject(forKey: extraCountKey)
    }
}
