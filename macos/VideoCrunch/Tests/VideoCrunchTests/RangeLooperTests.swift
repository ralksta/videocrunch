import AVFoundation
import XCTest
@testable import VideoCrunch

/// The trim editor plays the trimmed part over and over, nothing outside it.
@MainActor
final class RangeLooperTests: XCTestCase {

    /// A 4 s test clip, made with ffmpeg.
    private func clip() throws -> URL {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ffmpeg else { throw XCTSkip("needs ffmpeg") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("looper_\(UUID().uuidString).mp4")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc=duration=4:size=320x180:rate=30",
                          "-c:v", "libx264", "-preset", "ultrafast", url.path]
        try proc.run()
        proc.waitUntilExit()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Plays for `seconds`, noting where the player is every 50 ms.
    private func play(_ player: AVPlayer, for seconds: Double) async -> [Double] {
        player.play()
        var seen: [Double] = []
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            try? await Task.sleep(nanoseconds: 50_000_000)
            seen.append(player.currentTime().seconds)
        }
        player.pause()
        return seen
    }

    func testPlaybackStaysInTheTrimAndLoops() async throws {
        let player = AVPlayer(url: try clip())
        let looper = RangeLooper(player: player, start: 1.0, end: 2.0)
        await player.seek(to: CMTime(seconds: 1.0, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
        let seen = await play(player, for: 3.0)
        XCTAssertLessThan(seen.max() ?? 99, 2.2, "never far past the end")
        XCTAssertGreaterThan(seen.min() ?? 0, 0.9, "never before the start")
        // 3 s of a 1 s range: it went back to the start at least once.
        let jumpsBack = zip(seen, seen.dropFirst()).filter { $0 - $1 > 0.5 }.count
        XCTAssertGreaterThanOrEqual(jumpsBack, 1)
        _ = looper
    }

    func testAnUntrimmedVideoLoopsAtItsEnd() async throws {
        let player = AVPlayer(url: try clip())
        let looper = RangeLooper(player: player, start: 0, end: 4.0)
        await player.seek(to: CMTime(seconds: 3.0, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
        let seen = await play(player, for: 2.0)
        XCTAssertLessThan(seen.last ?? 99, 2.0, "back at the start after the file's end")
        _ = looper
    }

    func testPlayingFromBeforeTheTrimJumpsIntoIt() async throws {
        let player = AVPlayer(url: try clip())
        let looper = RangeLooper(player: player, start: 2.0, end: 3.0)
        let seen = await play(player, for: 0.6)
        XCTAssertGreaterThan(seen.last ?? 0, 1.9)
        _ = looper
    }
}
