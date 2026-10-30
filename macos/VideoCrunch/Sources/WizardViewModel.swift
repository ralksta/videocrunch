import Foundation
import Combine

enum WizardStep {
    case scanning
    case candidateSelection
    case options
    case encoding
    case completed
}

@MainActor
class WizardViewModel: ObservableObject {
    @Published var targetURL: URL?
    @Published var currentStep: WizardStep = .scanning
    @Published var errorMessage: String?

    // Step 1: Scan Results
    @Published var candidates: [Candidate] = []
    @Published var selectedIds: Set<String> = []
    @Published var scanSummary: ScanSummary?
    @Published var isScanning: Bool = false
    @Published var scanProgressText: String = "Lese Ordner und Metadaten..."

    // Step 2 & 3: Options
    @Published var targetCodec: String = "hevc"
    /// The codec the savings estimate was computed for.
    @Published var scannedCodec: String = "hevc"
    @Published var audioMode: String = "enhanced"
    @Published var scaleTo1080p: Bool = false
    @Published var moveToTrash: Bool = false
    @Published var minSSIMOverride: Double? = nil

    // Step 4: Encoding
    @Published var workers: [Int: WorkerStatus] = [:]
    @Published var completedCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var totalToEncode: Int = 0
    @Published var logs: [String] = []
    @Published var isEncoding: Bool = false
    @Published var wasCancelled: Bool = false
    @Published var encodeStartedAt: Date? = nil

    // Step 5: Completed
    @Published var batchResults: [BatchItemResult] = []
    @Published var actualSavedBytes: Int64 = 0
    @Published var retryEligibleCandidates: [Candidate] = []
    @Published var suggestedFloor: Double? = nil

    private var currentProcess: Process?
    var scriptDir: URL

    init() {
        // install_macos_quick_action.sh records the checkout it ran from;
        // without a bundle (binary started by hand) the working directory.
        if let repo = Bundle.main.object(forInfoDictionaryKey: "VideoCrunchRepoPath") as? String {
            self.scriptDir = URL(fileURLWithPath: repo)
        } else {
            self.scriptDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
    }

    func setRepoPath(_ path: String) {
        self.scriptDir = URL(fileURLWithPath: path)
    }

    func startScan(for url: URL) {
        self.targetURL = url
        self.errorMessage = nil
        self.currentStep = .scanning
        self.isScanning = true
        self.candidates = []
        self.selectedIds = []

        let python = self.resolvePythonPath()
        let scanScript = self.scriptDir.appendingPathComponent("scan.py").path
        let codec = self.targetCodec
        self.scannedCodec = codec

        // Run scan.py --json on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: python)
            proc.arguments = [scanScript, url.path, "--json", "--codec", codec]
            proc.environment = WizardViewModel.toolEnvironment()

            let pipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = errPipe

            do {
                try proc.run()
                // Drain stderr alongside stdout: on a big folder the progress
                // counter fills its 64 KB pipe and scan.py would block forever.
                let errBuffer = LineBuffer()
                let errReader = DispatchGroup()
                errReader.enter()
                DispatchQueue.global(qos: .utility).async {
                    errBuffer.store(errPipe.fileHandleForReading.readDataToEndOfFile())
                    errReader.leave()
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                errReader.wait()

                if proc.terminationStatus != 0 {
                    let errData = errBuffer.stored
                    let errStr = WizardViewModel.lastMessage(errData) ?? "Scan fehlgeschlagen"
                    DispatchQueue.main.async {
                        self.errorMessage = errStr
                        self.isScanning = false
                    }
                    return
                }

                if let response = try? JSONDecoder().decode(ScanResponse.self, from: data) {
                    DispatchQueue.main.async {
                        self.candidates = response.results
                        self.scanSummary = response.summary
                        self.selectedIds = Set(response.results.map { $0.id })
                        self.isScanning = false
                        self.currentStep = .candidateSelection
                    }
                } else {
                    DispatchQueue.main.async {
                        self.errorMessage = "Keine lesbaren Ergebnisse von scan.py erhalten."
                        self.isScanning = false
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Fehler beim Starten von scan.py: \(error.localizedDescription)"
                    self.isScanning = false
                }
            }
        }
    }

    var selectedCandidates: [Candidate] {
        candidates.filter { selectedIds.contains($0.id) }
    }

    var selectedTotalMB: Double {
        selectedCandidates.reduce(0.0) { $0 + $1.size_mb }
    }

    /// Follows the 1080p switch: with it on, downscalable files count with
    /// their downscaled estimate.
    var selectedEstimatedSavedMB: Double {
        selectedCandidates.reduce(0.0) { sum, c in
            sum + (scaleTo1080p ? (c.estimated_saved_mb_1080 ?? c.estimated_saved_mb)
                                : c.estimated_saved_mb)
        }
    }

    /// What switching the 1080p downscale on adds to the selection's saving.
    var downscaleExtraSavedMB: Double {
        selectedCandidates.reduce(0.0) { sum, c in
            sum + max(0, (c.estimated_saved_mb_1080 ?? c.estimated_saved_mb) - c.estimated_saved_mb)
        }
    }

    var selectedTotalAfterMB: Double {
        max(0, selectedTotalMB - selectedEstimatedSavedMB)
    }

    var cancelledCount: Int {
        batchResults.filter { $0.status == "cancelled" }.count
    }

    // scan.py decides what is above 1080p (by the short side, so a vertical
    // 1080x1920 video is not); it reports a 1080p estimate only for those.
    var hasTallCandidates: Bool {
        selectedCandidates.contains { $0.canDownscale }
    }

    var tallCandidatesCount: Int {
        selectedCandidates.filter { $0.canDownscale }.count
    }

    func selectAll() {
        selectedIds = Set(candidates.map { $0.id })
    }

    func deselectAll() {
        selectedIds.removeAll()
    }

    func toggleSelection(for id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    // Step navigation
    func proceedToOptions() {
        if selectedIds.isEmpty { return }
        currentStep = .options
    }

    func backToCandidates() {
        currentStep = .candidateSelection
    }

    func startEncoding() {
        guard !selectedIds.isEmpty else { return }

        currentStep = .encoding
        isEncoding = true
        logs = []
        workers = [:]
        completedCount = 0
        failedCount = 0
        totalToEncode = selectedIds.count
        wasCancelled = false
        encodeStartedAt = Date()
        batchResults = []
        suggestedFloor = nil
        retryEligibleCandidates = []

        let toProcess = selectedCandidates.map { $0.file_path }
        let tempDir = FileManager.default.temporaryDirectory
        let resultJsonPath = tempDir.appendingPathComponent("videocrunch_batch_\(UUID().uuidString).json").path
        // One path per line: --files splits on commas, and names contain them.
        let fileListURL = tempDir.appendingPathComponent("videocrunch_files_\(UUID().uuidString).txt")

        let python = self.resolvePythonPath()
        let batchScript = self.scriptDir.appendingPathComponent("batch.py").path
        let audioM = self.audioMode
        let scale1080 = self.scaleTo1080p
        let trash = self.moveToTrash
        let ssimFloor = self.minSSIMOverride
        let codec = self.targetCodec

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try toProcess.map { $0 + "\n" }.joined().write(to: fileListURL, atomically: true, encoding: .utf8)
            } catch {
                DispatchQueue.main.async {
                    self.isEncoding = false
                    self.errorMessage = "Dateiliste konnte nicht geschrieben werden: \(error.localizedDescription)"
                }
                return
            }
            defer { try? FileManager.default.removeItem(at: fileListURL) }

            var args = [
                batchScript,
                "--files-from", fileListURL.path,
                "--audio-mode", audioM,
                "--codec", codec,
                "--json-out", resultJsonPath
            ]

            if scale1080 {
                args.append(contentsOf: ["--scale-height", "1080"])
            }
            if trash {
                args.append("--replace")
            }
            if let floor = ssimFloor {
                args.append(contentsOf: ["--min-ssim", String(floor)])
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: python)
            proc.arguments = args
            proc.environment = WizardViewModel.toolEnvironment()

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            DispatchQueue.main.async {
                self.currentProcess = proc
            }

            let fileHandle = pipe.fileHandleForReading
            let lineBuffer = LineBuffer()
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let lines = lineBuffer.lines(after: data)
                guard !lines.isEmpty else { return }

                DispatchQueue.main.async {
                    self.parseBatchOutput(lines)
                }
            }

            do {
                try proc.run()
                proc.waitUntilExit()
                fileHandle.readabilityHandler = nil

                var report: BatchReport? = nil
                if let data = try? Data(contentsOf: URL(fileURLWithPath: resultJsonPath)) {
                    report = try? JSONDecoder().decode(BatchReport.self, from: data)
                }

                let finalReport = report
                DispatchQueue.main.async {
                    self.isEncoding = false
                    self.currentProcess = nil
                    self.finishBatch(report: finalReport)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isEncoding = false
                    self.errorMessage = "Fehler beim Ausführen von batch.py: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelEncoding() {
        wasCancelled = true
        currentProcess?.terminate()
        currentProcess = nil
        isEncoding = false
        logs.append("⚠️ Vorgang durch Benutzer abgebrochen.")
    }

    private func parseBatchOutput(_ lines: [String]) {
        for line in lines {
            logs.append(line)
            if logs.count > 100 { logs.removeFirst() }

            if let match = line.range(of: #"\s*\[(\d+)\]\s+(.*?)\s+(.*?)$"#, options: .regularExpression) {
                let sub = String(line[match])
                let scanner = Scanner(string: sub)
                _ = scanner.scanString("[")
                if let wid = scanner.scanInt() {
                    _ = scanner.scanString("]")
                    var status = "running"
                    var prog = 0
                    var q = 0

                    if line.contains("✓ Done") {
                        status = "done"
                        prog = 100
                    } else if line.contains("✗ Failed") {
                        status = "failed"
                    } else if line.contains("⊘ Skip") {
                        status = "skipped"
                    } else if line.contains("■ Cancelled") {
                        status = "cancelled"
                    }

                    if let pctRange = line.range(of: #"(\d+)%"#, options: .regularExpression) {
                        let pctStr = line[pctRange].replacingOccurrences(of: "%", with: "")
                        prog = Int(pctStr) ?? prog
                    }

                    if let qRange = line.range(of: #"Q=(\d+)"#, options: .regularExpression) {
                        let qStr = line[qRange].replacingOccurrences(of: "Q=", with: "")
                        q = Int(qStr) ?? q
                    }

                    var curr = workers[wid] ?? WorkerStatus(id: wid, file: "", status: status, progress: prog, q: q)
                    // "[2] clip.mov   Q=65 ..." — an idle slot has no name, only padding.
                    if let nameRange = line.range(of: #"\[\d+\] \S.*?\s{2,}"#, options: .regularExpression) {
                        let raw = line[nameRange]
                        if let close = raw.firstIndex(of: "]") {
                            let name = raw[raw.index(after: close)...].trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty { curr.file = name }
                        }
                    }
                    curr.status = status
                    curr.progress = prog
                    if q > 0 { curr.q = q }
                    workers[wid] = curr
                }
            }

            if line.contains("✓") && line.contains("✗") {
                if let succRange = line.range(of: #"✓\s*(\d+)"#, options: .regularExpression) {
                    let sStr = line[succRange].replacingOccurrences(of: "✓", with: "").trimmingCharacters(in: .whitespaces)
                    self.completedCount = Int(sStr) ?? self.completedCount
                }
                if let failRange = line.range(of: #"✗\s*(\d+)"#, options: .regularExpression) {
                    let fStr = line[failRange].replacingOccurrences(of: "✗", with: "").trimmingCharacters(in: .whitespaces)
                    self.failedCount = Int(fStr) ?? self.failedCount
                }
            }
        }
    }

    private func finishBatch(report: BatchReport?) {
        self.batchResults = report?.results ?? []
        self.actualSavedBytes = self.batchResults.reduce(0) { $0 + ($1.saved_bytes ?? 0) }
        // The live counters come from batch.py's table, which may stop
        // redrawing before the last file is counted; the report is final.
        if report != nil {
            self.completedCount = self.batchResults.filter { $0.status == "success" }.count
            self.failedCount = self.batchResults.filter { $0.status == "failed" }.count
        }

        let failedWithSSIM = self.batchResults.filter { ($0.status == "failed") && ($0.ssim != nil) }
        if !failedWithSSIM.isEmpty {
            let ssims = failedWithSSIM.compactMap { $0.ssim }
            if let lowest = ssims.min() {
                self.suggestedFloor = (lowest * 100).rounded() / 100.0 - 0.01
                let failedPaths = Set(failedWithSSIM.compactMap { $0.path })
                self.retryEligibleCandidates = candidates.filter { failedPaths.contains($0.file_path) }
            }
        }

        self.currentStep = .completed

        sendNotification(
            title: wasCancelled ? "videocrunch abgebrochen" : "videocrunch fertig",
            body: "\(completedCount) von \(totalToEncode) Videos optimiert. \(formatBytes(actualSavedBytes)) gespart."
        )
    }

    func retryFailedWithNewFloor() {
        guard let floor = suggestedFloor else { return }
        self.minSSIMOverride = floor
        self.selectedIds = Set(retryEligibleCandidates.map { $0.id })
        self.startEncoding()
    }

    private func sendNotification(title: String, body: String) {
        let script = "display notification \"\(body)\" with title \"\(title)\" sound name \"Glass\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    /// Apps started from Finder only get /usr/bin:/bin:/usr/sbin:/sbin, so the
    /// Homebrew ffmpeg/ffprobe the Python scripts call would not be found.
    nonisolated static func toolEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin"]
        let current = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (extra.filter { !current.contains($0) } + current).joined(separator: ":")
        return env
    }

    /// Last non-empty line of a script's stderr, without ANSI colours or the
    /// carriage-return progress counter.
    nonisolated static func lastMessage(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return stripANSI(text)
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    /// Colours and cursor moves (batch.py redraws its table in place).
    nonisolated static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    func resolvePythonPath() -> String {
        let venvPython = scriptDir.appendingPathComponent(".venv/bin/python3").path
        if FileManager.default.isExecutableFile(atPath: venvPython) {
            return venvPython
        }
        // Like crunch.sh: the first python3 on PATH. Homebrew's comes before
        // /usr/bin/python3, which is 3.9 and can't parse `float | None`.
        let path = WizardViewModel.toolEnvironment()["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/python3"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "/usr/bin/python3"
    }
}

/// Turns a pipe's chunks into whole lines. A read can stop mid-line, and
/// batch.py ends its redraws with "\r" as often as with "\n". Splitting on
/// bytes is safe for UTF-8: 0x0A and 0x0D never occur inside a character.
/// Used from one reader thread at a time, never concurrently.
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private(set) var stored = Data()

    func store(_ data: Data) {
        stored = data
    }

    func lines(after data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let raw = pending.subdata(in: pending.startIndex..<end)
            pending = pending.subdata(in: (end + 1)..<pending.endIndex)
            let line = WizardViewModel.stripANSI(String(decoding: raw, as: UTF8.self))
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(line)
            }
        }
        return lines
    }
}
