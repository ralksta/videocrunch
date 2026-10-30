import AVFoundation
import AVKit
import SwiftUI

/// Cut a single video before encoding: a preview, a filmstrip and two
/// handles — the trim bar QuickTime and Gifski use.
struct TrimEditor: View {
    let url: URL
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double

    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let player {
                PlayerView(player: player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            TrimTimeline(url: url, duration: duration, start: $start, end: $end) { time in
                player?.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero)
            }
            .frame(height: 52)
            HStack(spacing: 14) {
                timeLabel("Anfang", start)
                timeLabel("Ende", end)
                timeLabel("Länge", end - start)
                Spacer()
                if start > 0 || end < duration {
                    Button("Zurücksetzen") {
                        start = 0
                        end = duration
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .cardBackground()
        .onAppear {
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
        }
    }

    private func timeLabel(_ title: String, _ seconds: Double) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(clock(seconds))
                .monospacedDigit()
        }
        .font(.caption)
    }
}

/// AppKit's player view (the one QuickTime uses). SwiftUI's VideoPlayer
/// aborted while being created on this system, before any video loaded.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}

/// "1:05", "1:02:07" — the way QuickTime shows times.
func clock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// Filmstrip with a yellow selection whose ends are dragged.
private struct TrimTimeline: View {
    let url: URL
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    /// Called with the time under the handle being dragged, for the preview.
    let scrub: (Double) -> Void

    @State private var frames: [CGImage] = []
    private let minimumLength = 1.0
    private let frameCount = 12

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = { (t: Double) in width * CGFloat(t / max(duration, 0.001)) }
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { i in
                        Image(decorative: frames[i], scale: 2)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width / CGFloat(frameCount), height: geo.size.height)
                            .clipped()
                    }
                }
                .frame(width: width, height: geo.size.height, alignment: .leading)
                .background(Color.secondary.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                // What is cut away is dimmed.
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: x(start))
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(0, width - x(end)))
                    .offset(x: x(end))

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .frame(width: max(6, x(end) - x(start)))
                    .offset(x: x(start))
                    .allowsHitTesting(false)

                handle(at: x(start), label: "Anfang") { location in
                    start = min(max(0, time(location, width)), end - minimumLength)
                    scrub(start)
                }
                handle(at: x(end) - 14, label: "Ende") { location in
                    end = max(min(duration, time(location + 14, width)), start + minimumLength)
                    scrub(end)
                }
            }
            .coordinateSpace(name: "trim")
        }
        .task(id: url) {
            frames = await Self.filmstrip(url: url, duration: duration, count: frameCount)
        }
    }

    private func time(_ location: CGFloat, _ width: CGFloat) -> Double {
        Double(location / max(width, 1)) * duration
    }

    private func handle(at x: CGFloat, label: String,
                        drag: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.yellow)
            .frame(width: 14)
            .overlay(Capsule().fill(.black.opacity(0.45)).frame(width: 3, height: 16))
            .offset(x: x)
            .gesture(DragGesture(coordinateSpace: .named("trim")).onChanged { value in
                drag(value.location.x)
            })
            .accessibilityElement()
            .accessibilityLabel(label)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    static func filmstrip(url: URL, duration: Double, count: Int) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 136)
        var images: [CGImage] = []
        for i in 0..<count {
            let seconds = duration * (Double(i) + 0.5) / Double(count)
            if let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                images.append(frame.image)
            }
        }
        return images
    }
}
