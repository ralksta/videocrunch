import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - Colours

extension Color {
    /// Green for saved megabytes. The system green is too light to read as
    /// text on a light background, so light mode gets a deeper one.
    static let savings = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .systemGreen
            : NSColor(srgbRed: 0.10, green: 0.55, blue: 0.22, alpha: 1)
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
    @State private var image: NSImage?

    var body: some View {
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

// MARK: - Before / after

/// A finished encode next to its source, for the comparison window.
struct Comparison: Identifiable, Codable, Hashable {
    let source: URL
    let encoded: URL
    var id: String { encoded.path }
}

/// Where in the clip the comparison frame is taken.
enum FramePosition: Int, CaseIterable, Identifiable {
    case start, middle, end
    var id: Int { rawValue }
    var label: String { ["Anfang", "Mitte", "Ende"][rawValue] }
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
                    Text(comparison.source.lastPathComponent)
                        .font(.headline)
                    Text("Links das Original, rechts das Ergebnis – Trennlinie ziehen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Stelle", selection: $position) {
                    ForEach(FramePosition.allCases) { place in
                        Text(place.label).tag(place)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                Toggle("100 %", isOn: $actualSize)
                    .toggleStyle(.button)
                    .help("In Originalgröße zeigen, um Details zu beurteilen")
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
                Button("Schließen") { dismiss() }
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
                                                       at: position.fraction)
            } catch {
                failure = "Bild konnte nicht gelesen werden."
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
                tag("Original")
                Spacer()
                tag("Neu")
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
        .accessibilityLabel("Vergleich Original und Ergebnis")
        .accessibilityValue("\(Int(split * 100)) % Original")
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
    static func frames(source: URL, encoded: URL, at position: Double) async throws
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
            for (input, output) in [(source, sourcePNG), (encoded, encodedPNG)] {
                try run(["ffmpeg", "-v", "error", "-y", "-ss", String(format: "%.3f", time),
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
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = args
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
