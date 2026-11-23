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
    @State private var looper: RangeLooper?
    /// Where the preview is, shown as a line on the filmstrip.
    @State private var playhead: Double = 0
    /// The filmstrip shows only this stretch when zoomed (the Lupe), so a
    /// few seconds of a long video are more than a few pixels wide.
    @State private var window: ClosedRange<Double>?
    /// One frame duration, updated from the video track's nominal frame rate.
    @State private var frameStep: Double = 1.0 / 30.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Takes what the window leaves: small on a laptop, larger when there is room.
            Group {
                if let player {
                    PlayerView(player: player)
                } else {
                    Color.black
                }
            }
            .frame(minHeight: 140, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            TrimTimeline(url: url, duration: duration, visible: window ?? 0...duration,
                         start: $start, end: $end, playhead: playhead) { time in
                seek(time)
            }
            .frame(height: 52)
            HStack(spacing: 8) {
                timeLabel(L("trim.start"), start)
                timeLabel(L("trim.end"), end)
                timeLabel(L("trim.length"), end - start)
                Spacer(minLength: 4)
                Button {
                    stepPlayhead(by: -frameStep)
                } label: {
                    Image(systemName: "chevron.left")
                        .accessibilityLabel(L("trim.step_back"))
                }
                .help(L("trim.step_back_help"))
                .keyboardShortcut(.leftArrow, modifiers: [])
                Button {
                    stepPlayhead(by: frameStep)
                } label: {
                    Image(systemName: "chevron.right")
                        .accessibilityLabel(L("trim.step_fwd"))
                }
                .help(L("trim.step_fwd_help"))
                .keyboardShortcut(.rightArrow, modifiers: [])
                Button(L("trim.step_back")) { stepPlayhead(by: -1.0) }
                    .keyboardShortcut(.leftArrow, modifiers: .shift)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                Button(L("trim.step_fwd")) { stepPlayhead(by: 1.0) }
                    .keyboardShortcut(.rightArrow, modifiers: .shift)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                Button {
                    start = min(playhead, end - TrimTimeline.minimumLength)
                    Haptics.tap(.alignment)
                } label: {
                    Image(systemName: "arrow.right.to.line")
                        .accessibilityLabel(L("trim.set_start"))
                }
                .help(L("trim.set_start_help"))
                .keyboardShortcut("i", modifiers: [])
                Button {
                    end = max(playhead, start + TrimTimeline.minimumLength)
                    Haptics.tap(.alignment)
                } label: {
                    Image(systemName: "arrow.left.to.line")
                        .accessibilityLabel(L("trim.set_end"))
                }
                .help(L("trim.set_end_help"))
                .keyboardShortcut("o", modifiers: [])
                if window == nil {
                    Button {
                        zoom(true)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                        .accessibilityLabel(L("trim.zoom_in"))
                    }
                    .help(L("trim.zoom_in_help"))
                } else {
                    Button {
                        zoom(false)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                        .accessibilityLabel(L("trim.zoom_out"))
                    }
                    .buttonStyle(.borderedProminent)
                    .help(L("trim.zoom_out_help"))
                }
                if start > 0 || end < duration {
                    Button(L("action.reset")) {
                        start = 0
                        end = duration
                        window = nil
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .cardBackground()
        .onAppear {
            let player = AVPlayer(url: url)
            self.player = player
            looper = RangeLooper(player: player, start: start, end: end) { playhead = $0 }
        }
        .task(id: url) {
            if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
               let fps = try? await track.load(.nominalFrameRate),
               fps > 1 {
                frameStep = 1.0 / Double(fps)
            }
        }
        .onDisappear {
            player?.pause()
            looper = nil
        }
        .onChange(of: start) { looper?.update(start: start, end: end) }
        .onChange(of: end) { looper?.update(start: start, end: end) }
    }

    private func seek(_ time: Double) {
        playhead = time
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func stepPlayhead(by delta: Double) {
        player?.pause()
        let next = TrimTimeline.nudgedTime(playhead, delta: delta, bounds: 0...duration)
        seek(next)
    }

    /// Thirty seconds around the selection (more if it is longer), or all.
    private func zoom(_ on: Bool) {
        guard on else { window = nil; return }
        window = TrimTimeline.zoomWindow(start: start, end: end, duration: duration)
    }

    private func timeLabel(_ title: String, _ seconds: Double) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(preciseClock(seconds))
                .monospacedDigit()
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
    }
}

/// Plays only the trimmed part, over and over — what the result will be,
/// as QuickTime and Gifski play a trim.
@MainActor
final class RangeLooper {
    private let player: AVPlayer
    private var start: Double
    private var end: Double
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    /// `onTime` hears where the player is, every 50 ms.
    init(player: AVPlayer, start: Double, end: Double, onTime: @escaping (Double) -> Void = { _ in }) {
        self.player = player
        self.start = start
        self.end = end
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                onTime(time.seconds)
                self?.check(time.seconds)
            }
        }
        // An untrimmed end is the file's end, where the player would stop.
        player.actionAtItemEnd = .none
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func update(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    /// While playing: past the end, or before the start, back to the start.
    /// Paused, the handles may scrub anywhere.
    private func check(_ now: Double) {
        guard player.rate != 0, now >= end || now < start - 0.1 else { return }
        restart()
    }

    private func restart() {
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
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

/// "0:02.4": tenths, for trims a few seconds long.
func preciseClock(_ seconds: Double) -> String {
    let tenths = max(0, Int((seconds * 10).rounded()))
    let m = tenths / 600, s = (tenths % 600) / 10, t = tenths % 10
    return String(format: "%d:%02d.%d", m, s, t)
}

/// Filmstrip with a yellow selection whose ends are dragged.
struct TrimTimeline: View {
    let url: URL
    let duration: Double
    /// The stretch of the video the strip spans: all of it, or the Lupe's.
    let visible: ClosedRange<Double>
    @Binding var start: Double
    @Binding var end: Double
    let playhead: Double
    /// Called with the time under the handle being dragged, or clicked on
    /// the strip, for the preview.
    let scrub: (Double) -> Void

    @State private var frames: [CGImage] = []
    @State private var dragOrigin: (start: Double, end: Double)?
    @State private var hoveringSelection = false
    @State private var handPushed = false
    @State private var hitBoundary = false
    static let minimumLength = 0.5
    static let handleWidth: CGFloat = 14
    private let frameCount = 12

    private var isSelectionMovable: Bool {
        start > 0.001 || end < duration - 0.001
    }

    /// Shift the entire `[start, end]` window by `delta`, keeping its length intact inside `0...duration`.
    static func shiftedRange(start: Double, end: Double, delta: Double,
                             duration: Double) -> (start: Double, end: Double) {
        guard duration > 0 else { return (start, end) }
        let length = min(duration, max(minimumLength, end - start))
        let maxStart = max(0, duration - length)
        let newStart = min(max(0, start + delta), maxStart)
        return (newStart, min(duration, newStart + length))
    }

    /// Nudge a playhead timestamp by `delta` within `bounds`.
    static func nudgedTime(_ time: Double, delta: Double, bounds: ClosedRange<Double>) -> Double {
        min(bounds.upperBound, max(bounds.lowerBound, time + delta))
    }

    /// What the Lupe shows: the selection with room on both sides, at least
    /// 30 s, inside the video.
    static func zoomWindow(start: Double, end: Double, duration: Double) -> ClosedRange<Double> {
        let length = min(duration, max(30, (end - start) * 3))
        let lo = min(max(0, (start + end) / 2 - length / 2), duration - length)
        return max(0, lo)...(max(0, lo) + length)
    }

    var body: some View {
        GeometryReader { geo in
            // The handles sit outside the selection, so even half a second
            // between them leaves both to grab; the strip leaves them room.
            let h = Self.handleWidth
            let width = geo.size.width - 2 * h
            let span = max(visible.upperBound - visible.lowerBound, 0.001)
            let x = { (t: Double) in
                h + min(width, max(0, width * CGFloat((t - visible.lowerBound) / span)))
            }
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
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .named("trim")) { location in
                    scrub(time(location.x, width))
                }
                .offset(x: h)

                // What is cut away is dimmed.
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: x(start) - h)
                    .offset(x: h)
                    .allowsHitTesting(false)
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(0, width + h - x(end)))
                    .offset(x: x(end))
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .frame(width: x(end) - x(start) + 2 * h)
                    .offset(x: x(start) - h)
                    .allowsHitTesting(false)

                // Dragging inside a trimmed selection slides the whole window across the clip;
                // tapping still seeks the playhead.
                Color.clear
                    .frame(width: max(0, x(end) - x(start)), height: geo.size.height)
                    .contentShape(Rectangle())
                    .offset(x: x(start))
                    .onTapGesture(coordinateSpace: .named("trim")) { location in
                        scrub(time(location.x, width))
                    }
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .named("trim"))
                            .onChanged { value in
                                guard isSelectionMovable else { return }
                                if dragOrigin == nil {
                                    dragOrigin = (start, end)
                                }
                                guard let origin = dragOrigin else { return }
                                let delta = Double(value.translation.width / max(width, 1)) * span
                                let shifted = Self.shiftedRange(start: origin.start, end: origin.end,
                                                                delta: delta, duration: duration)
                                start = shifted.start
                                end = shifted.end
                                checkBoundary(shifted.start <= 0.001 || shifted.end >= duration - 0.001)
                                scrub(shifted.start)
                            }
                            .onEnded { _ in
                                dragOrigin = nil
                                hitBoundary = false
                            }
                    )
                    .onHover { inside in
                        hoveringSelection = inside
                        syncHandCursor()
                    }
                    .onChange(of: isSelectionMovable) {
                        syncHandCursor()
                    }
                    .onDisappear {
                        hoveringSelection = false
                        syncHandCursor()
                    }

                if visible.contains(playhead) {
                    Rectangle().fill(.white)
                        .frame(width: 2)
                        .shadow(radius: 1)
                        .offset(x: x(playhead) - 1)
                        .allowsHitTesting(false)
                }

                handle(at: x(start) - h, label: "Anfang", drag: { location in
                    let raw = time(location + h / 2, width)
                    let clamped = min(max(0, raw), end - Self.minimumLength)
                    checkBoundary(raw <= 0 || raw >= end - Self.minimumLength)
                    start = clamped
                    scrub(start)
                }, endDrag: { hitBoundary = false })
                handle(at: x(end), label: "Ende", drag: { location in
                    let raw = time(location - h / 2, width)
                    let clamped = max(min(duration, raw), start + Self.minimumLength)
                    checkBoundary(raw >= duration || raw <= start + Self.minimumLength)
                    end = clamped
                    scrub(end)
                }, endDrag: { hitBoundary = false })
            }
            .coordinateSpace(name: "trim")
        }
        .task(id: visible) {
            frames = await Self.filmstrip(url: url, range: visible, count: frameCount)
        }
    }

    /// The time at `location` in the strip's coordinates (handle room included).
    private func time(_ location: CGFloat, _ width: CGFloat) -> Double {
        let fraction = Double(min(max(location - Self.handleWidth, 0), width) / max(width, 1))
        return visible.lowerBound + fraction * (visible.upperBound - visible.lowerBound)
    }

    private func syncHandCursor() {
        let shouldShow = hoveringSelection && isSelectionMovable
        if shouldShow && !handPushed {
            NSCursor.openHand.push()
            handPushed = true
        } else if !shouldShow && handPushed {
            NSCursor.pop()
            handPushed = false
        }
    }

    private func checkBoundary(_ atEdge: Bool) {
        if atEdge && !hitBoundary {
            hitBoundary = true
            Haptics.tap(.alignment)
        } else if !atEdge {
            hitBoundary = false
        }
    }

    private func handle(at x: CGFloat, label: String,
                        drag: @escaping (CGFloat) -> Void,
                        endDrag: @escaping () -> Void = {}) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.yellow)
            .frame(width: Self.handleWidth)
            .overlay(Capsule().fill(.black.opacity(0.45)).frame(width: 3, height: 16))
            .offset(x: x)
            .gesture(
                DragGesture(coordinateSpace: .named("trim"))
                    .onChanged { value in drag(value.location.x) }
                    .onEnded { _ in endDrag() }
            )
            .accessibilityElement()
            .accessibilityLabel(label)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    static func filmstrip(url: URL, range: ClosedRange<Double>, count: Int) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 136)
        let tolerance = CMTime(seconds: (range.upperBound - range.lowerBound) / Double(count * 4),
                               preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var images: [CGImage] = []
        for i in 0..<count {
            let seconds = range.lowerBound
                + (range.upperBound - range.lowerBound) * (Double(i) + 0.5) / Double(count)
            if let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                images.append(frame.image)
            }
        }
        return images
    }
}
