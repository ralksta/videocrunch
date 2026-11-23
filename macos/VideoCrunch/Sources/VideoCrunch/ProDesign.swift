import AppKit
import AVFoundation
import QuickLookThumbnailing
import SwiftUI

// MARK: - Colours

extension Color {
    /// Green for saved megabytes. Harmonized with the brand teal and kept high-contrast
    /// in both dark and light appearances.
    static let savings = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.28, green: 0.80, blue: 0.54, alpha: 1)
            : NSColor(srgbRed: 0.09, green: 0.52, blue: 0.28, alpha: 1)
    })
}

// MARK: - Windows

/// Keeps a window out of state restoration: a comparison reopened at the
/// next launch would show a run that is long over.
struct NotRestorable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.isRestorable = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Thumbnails

/// The frame Finder shows for a video, from Quick Look.
struct VideoThumbnail: View {
    let url: URL
    var duration: Double? = nil
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                }
            }
            if let duration, duration > 0 {
                Text(clock(duration))
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.black.opacity(0.68)))
                    .padding(3)
            }
        }
        .frame(width: 72, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .task(id: url) {
            image = await Self.thumbnail(for: url)
        }
    }

    static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 144, height: 96), scale: 2,
            representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

/// High-resolution 16:9 preview frame for the Encode stage.
struct VideoStagePreview: View {
    let url: URL
    let title: String
    var duration: Double? = nil
    var trimRange: (start: Double, end: Double)? = nil
    var badge: String? = nil
    var height: CGFloat? = nil

    @State private var image: NSImage?

    private var taskKey: String {
        "\(url.path)-\(trimRange?.start ?? -1)"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Color.black.opacity(0.88)
            .frame(maxWidth: .infinity)
            .modifier(StageAspectOrHeight(height: height))
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    CrunchMark(size: 40, squeeze: 0.25, scanning: false)
                        .opacity(0.65)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.60)))
                        .padding(10)
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    Spacer()
                    HStack(alignment: .bottom, spacing: 8) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if let trimRange {
                            Label("\(clock(trimRange.start))–\(clock(trimRange.end))", systemImage: "scissors")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(.black.opacity(0.65)))
                        } else if let duration, duration > 0 {
                            Text(clock(duration))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(.black.opacity(0.65)))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.78)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(Color(nsColor: .separatorColor))
            )
            .task(id: taskKey) {
                image = await Self.loadFrame(for: url, trimStart: trimRange?.start, duration: duration)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(stageAccessibilityValue)
    }

    private var stageAccessibilityValue: String {
        var parts: [String] = []
        if let badge, !badge.isEmpty {
            parts.append(badge)
        }
        if let trimRange {
            parts.append("\(clock(trimRange.start))–\(clock(trimRange.end))")
        } else if let duration, duration > 0 {
            parts.append(clock(duration))
        }
        return parts.joined(separator: ", ")
    }

    private struct StageAspectOrHeight: ViewModifier {
        let height: CGFloat?
        func body(content: Content) -> some View {
            if let height {
                content.frame(height: height)
            } else {
                content.aspectRatio(16 / 9, contentMode: .fit)
            }
        }
    }

    static func loadFrame(for url: URL, trimStart: Double?, duration: Double?) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let trimStart {
            if let frame = await grabAssetFrame(url: url, atSeconds: max(0, trimStart)) {
                return frame
            }
        }
        let req = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 720, height: 405), scale: 2,
            representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
            return rep.nsImage
        }
        let fallbackSec = min(max((duration ?? 5) * 0.1, 0.2), 2.0)
        return await grabAssetFrame(url: url, atSeconds: fallbackSec)
    }

    private static func grabAssetFrame(url: URL, atSeconds seconds: Double) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        let cg = result.image
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Before / after

/// A finished encode next to its source, for the comparison window.
struct Comparison: Identifiable, Codable, Hashable {
    let source: URL
    let encoded: URL
    /// Where the encode starts in the source (seconds) when it was trimmed.
    var offset: Double = 0
    /// Shown instead of the file name, e.g. for a preview of a file.
    var title: String? = nil
    /// What was measured, shown under the title.
    var note: String? = nil
    var id: String { encoded.path }
}

/// Where in the clip the comparison frame is taken.
enum FramePosition: Int, CaseIterable, Identifiable {
    case start, middle, end
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .start: return L("comparison.start")
        case .middle: return L("comparison.middle")
        case .end: return L("comparison.end")
        }
    }
    var fraction: Double { [0.1, 0.5, 0.9][rawValue] }
}

/// The same frame of source and encode, one over the other behind a split
/// the user drags — judged by eye rather than by the SSIM number.
struct ComparisonSheet: View {
    let comparison: Comparison
    @Environment(\.dismiss) private var dismiss

    @State private var frames: (source: NSImage, encoded: NSImage)?
    @State private var failure: String?
    @State private var position = FramePosition.middle
    @State private var split = 0.5
    @State private var actualSize = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(comparison.title ?? comparison.source.lastPathComponent)
                        .font(.headline)
                    Text(comparison.note ?? L("comparison.default_note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L("comparison.position"), selection: $position) {
                    ForEach(FramePosition.allCases) { place in
                        Text(place.label).tag(place)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                Toggle("100 %", isOn: $actualSize)
                    .toggleStyle(.button)
                    .help(L("comparison.actual_size_help"))
            }
            .padding(16)

            Divider()

            ZStack {
                Color.black
                if let frames {
                    if actualSize {
                        let scroller = ScrollView([.horizontal, .vertical]) {
                            SplitImage(source: frames.source, encoded: frames.encoded,
                                       split: $split, size: frames.source.size)
                        }
                        // Start in the middle of the frame, where the subject usually is.
                        if #available(macOS 14.0, *) {
                            scroller.defaultScrollAnchor(.center)
                        } else {
                            scroller
                        }
                    } else {
                        GeometryReader { geo in
                            let size = fitted(frames.source.size, in: geo.size)
                            SplitImage(source: frames.source, encoded: frames.encoded,
                                       split: $split, size: size)
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                } else if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.white)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button(L("action.close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(12)
        }
        .frame(minWidth: 720, idealWidth: 1100, minHeight: 480, idealHeight: 760)
        .background(NotRestorable())
        .task(id: position) {
            frames = nil
            failure = nil
            do {
                frames = try await FrameGrabber.frames(source: comparison.source,
                                                       encoded: comparison.encoded,
                                                       at: position.fraction,
                                                       sourceOffset: comparison.offset)
            } catch {
                failure = L("comparison.load_error")
            }
        }
    }

    private func fitted(_ image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return box }
        let scale = min(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

/// Encode underneath, source on top cut off at `split`, and the handle.
private struct SplitImage: View {
    let source: NSImage
    let encoded: NSImage
    @Binding var split: Double
    let size: CGSize

    var body: some View {
        ZStack(alignment: .leading) {
            Image(nsImage: encoded)
                .resizable()
                .interpolation(.none)
            Image(nsImage: source)
                .resizable()
                .interpolation(.none)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: size.width * split)
                }
            Rectangle()
                .fill(.white)
                .frame(width: 2)
                .shadow(radius: 2)
                .overlay(
                    Image(systemName: "arrow.left.and.right.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white, Color.accentColor)
                        .shadow(radius: 3)
                )
                .offset(x: size.width * split - 1)
            HStack {
                tag(L("comparison.original"))
                Spacer()
                tag(L("comparison.new"))
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(10)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            split = min(1, max(0, value.location.x / max(size.width, 1)))
        })
        .accessibilityElement()
        .accessibilityLabel(L("comparison.a11y_label"))
        .accessibilityValue(L("comparison.a11y_value_fmt", Int(split * 100)))
        .accessibilityAdjustableAction { direction in
            split = min(1, max(0, split + (direction == .increment ? 0.1 : -0.1)))
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
    }
}

/// Pulls the same frame out of source and encode with ffmpeg, both through
/// the same scaler and colour conversion so neither is favoured.
enum FrameGrabber {
    static func frames(source: URL, encoded: URL, at position: Double,
                       sourceOffset: Double = 0) async throws
        -> (source: NSImage, encoded: NSImage) {
        try await Task.detached(priority: .userInitiated) {
            let env = WizardViewModel.toolEnvironment()
            let (width, height, duration) = try probe(encoded, env: env)
            let time = max(0, duration * position)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("videocrunch-compare-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let filter = "scale=\(width):\(height):flags=bicubic:out_color_matrix=bt709,format=rgb24"
            let sourcePNG = dir.appendingPathComponent("source.png")
            let encodedPNG = dir.appendingPathComponent("encoded.png")
            for (input, output, at) in [(source, sourcePNG, time + sourceOffset),
                                        (encoded, encodedPNG, time)] {
                try run(["ffmpeg", "-v", "error", "-y", "-ss", String(format: "%.3f", at),
                         "-i", input.path, "-frames:v", "1", "-vf", filter, output.path], env: env)
            }
            guard let sourceImage = NSImage(contentsOf: sourcePNG),
                  let encodedImage = NSImage(contentsOf: encodedPNG) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (sourceImage, encodedImage)
        }.value
    }

    private static func probe(_ url: URL, env: [String: String]) throws -> (Int, Int, Double) {
        let out = try run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                           "-show_entries", "stream=width,height:format=duration",
                           "-of", "default=noprint_wrappers=1", url.path], env: env)
        var values: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        guard let w = Int(values["width"] ?? ""), let h = Int(values["height"] ?? "") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (w, h, Double(values["duration"] ?? "") ?? 0)
    }

    @discardableResult
    private static func run(_ args: [String], env: [String: String]) throws -> String {
        let proc = Process()
        if let first = args.first, let toolURL = AppRuntime.executableURL(for: first, env: env) {
            proc.executableURL = toolURL
            proc.arguments = Array(args.dropFirst())
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = args
        }
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return String(decoding: data, as: UTF8.self)
    }
}
