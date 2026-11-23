import XCTest
@testable import VideoCrunch

final class SandboxAndRuntimeTests: XCTestCase {
    func testToolEnvironmentIsolatesSandboxedRunsFromHomebrew() {
        let env = AppRuntime.toolEnvironment(
            sandboxed: true,
            base: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        )
        let pathEntries = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertFalse(pathEntries.contains("/opt/homebrew/bin"))
        XCTAssertFalse(pathEntries.contains("/usr/local/bin"))
        XCTAssertTrue(pathEntries.contains("/usr/bin"))

        let logDir = env["VIDEOCRUNCH_LOG_DIR"] ?? ""
        XCTAssertTrue(logDir.hasSuffix("/VideoCrunch/logs"), "Unexpected sandbox log dir: \(logDir)")
    }

    func testToolEnvironmentPreservesHomebrewAndDotDirOutsideSandbox() {
        let env = AppRuntime.toolEnvironment(
            sandboxed: false,
            base: ["PATH": "/usr/bin:/bin"]
        )
        let pathEntries = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertTrue(pathEntries.contains("/opt/homebrew/bin"))
        XCTAssertTrue(pathEntries.contains("/usr/local/bin"))
        XCTAssertTrue(
            pathEntries.firstIndex(of: "/opt/homebrew/bin")! < pathEntries.firstIndex(of: "/usr/bin")!
        )

        let logDir = env["VIDEOCRUNCH_LOG_DIR"] ?? ""
        XCTAssertTrue(logDir.hasSuffix("/.videocrunch/logs"), "Unexpected CLI log dir: \(logDir)")
    }

    @MainActor
    func testSandboxCanWriteChecksRealDirectoryAndRejectsMissingOne() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-write-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let access = SandboxAccessManager(defaults: nil)
        XCTAssertTrue(access.canWrite(to: dir))
        XCTAssertFalse(access.canWrite(to: dir.appendingPathComponent("missing-folder")))
    }

    func testReplaceOriginalWithTrashRefusesCollisionWithExistingMP4() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-trash-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let originalMov = dir.appendingPathComponent("clip.mov")
        let unrelatedMP4 = dir.appendingPathComponent("clip.mp4")
        let encodedOpt = dir.appendingPathComponent("clip_opt.mp4")
        try Data("mov".utf8).write(to: originalMov)
        try Data("existing-mp4".utf8).write(to: unrelatedMP4)
        try Data("encoded".utf8).write(to: encodedOpt)

        let replaced = SandboxAccessManager.replaceOriginalWithTrash(original: originalMov, encoded: encodedOpt)
        XCTAssertNil(replaced)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalMov.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedMP4.path))
        XCTAssertEqual(try Data(contentsOf: unrelatedMP4), Data("existing-mp4".utf8))
    }
}
