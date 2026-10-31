import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum WizardStep {
    case scanning
    case candidateSelection
    case options
    case encoding
    case completed
}

@MainActor
class WizardViewModel: ObservableObject {
    /// What was opened — files and folders, scanned together.
    @Published var targetURLs: [URL] = []
    /// Opened while an encode runs; offered once it is done.
    @Published var queuedURLs: [URL] = []
    /// Shown in the selection list, e.g. when adding files failed.
    @Published var notice: String?
    /// Opened while a scan runs; added when it is done.
    private var scanBacklog: [URL] = []
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
    /// The sound as recorded unless the user asks for loudness levelling.
    @Published var audioMode: String = "standard"
    @Published var scaleTo1080p: Bool = false
    @Published var moveToTrash: Bool = false
    @Published var minSSIMOverride: Double? = nil
    /// Trim for a single selected video, in seconds of the source.
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    private var trimId: String?
    /// Video re-encode or GIF; the GIF needs the single video the trim is for.
    @Published var outputMode: OutputMode = .video
    @Published var gifWidth: Int = 480
    @Published var gifFPS: Int = 15
    @Published var gifQuality: Double = 90
    @Published var gifEstimate: GifEstimate?
    @Published var isEstimatingGif = false
    /// The finished GIF (or why there is none), for the last step.
    @Published var gifResult: GifResult?
    private var estimateWork: DispatchWorkItem?
    private var estimateGeneration = 0
    /// Where the last run's output starts in its source, for the comparison.
    private(set) var lastRunTrim: (path: String, start: Double)?

    // Step 4: Encoding
    @Published var workers: [Int: WorkerStatus] = [:]
    private var batchProgress = BatchProgress()
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
    /// Replaces the scan.py run when set — tests feed `scanFinished` directly.
    var scanner: ((_ urls: [URL], _ adding: Bool) -> Void)?

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

    /// Everything opened — Dock, Finder, Quick Action, drop, ⌘O — lands here.
    /// What happens depends on where the wizard is: before a selection it
    /// starts over, during one it adds, during an encode it waits.
    func open(_ urls: [URL]) {
        let known = Set(targetURLs + queuedURLs + scanBacklog)
        let fresh = urls.map(\.standardizedFileURL).filter { !known.contains($0) }
        guard !fresh.isEmpty else { return }
        switch currentStep {
        case .encoding:
            queuedURLs += fresh
        case .scanning where isScanning:
            scanBacklog += fresh
        case .candidateSelection, .options:
            targetURLs += fresh
            runScan(fresh, adding: true)
        default:  // empty start, failed scan, finished run
            startScan(for: fresh)
        }
    }

    func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .folder]
        if panel.runModal() == .OK {
            open(panel.urls)
        }
    }

    /// Back to the empty start screen after a finished run.
    func startOver() {
        targetURLs = []
        candidates = []
        selectedIds = []
        batchResults = []
        gifResult = nil
        errorMessage = nil
        notice = nil
        scaleTo1080p = false
        currentStep = .scanning
    }

    /// Scan what was queued during the encode, as a new run.
    func scanQueued() {
        let urls = queuedURLs
        queuedURLs = []
        startScan(for: urls)
    }

    func startScan(for urls: [URL]) {
        self.targetURLs = urls
        self.errorMessage = nil
        self.notice = nil
        self.currentStep = .scanning
        self.candidates = []
        self.selectedIds = []
        self.scaleTo1080p = false
        runScan(urls, adding: false)
    }

    /// Runs scan.py over `urls`. `adding` keeps the current selection and
    /// appends what is new instead of replacing the list.
    private func runScan(_ urls: [URL], adding: Bool) {
        self.isScanning = true
        if let scanner {
            scanner(urls, adding)
            return
        }
        let python = self.resolvePythonPath()
        let scanScript = self.scriptDir.appendingPathComponent("scan.py").path
        let codec = self.targetCodec
        if !adding {
            self.scannedCodec = codec
        }

        // Run scan.py --json on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: python)
            proc.arguments = [scanScript] + urls.map(\.path) + ["--json", "--codec", codec]
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
                        self.scanFailed(errStr, adding: adding)
                    }
                    return
                }

                if let response = try? JSONDecoder().decode(ScanResponse.self, from: data) {
                    DispatchQueue.main.async {
                        self.scanFinished(response, adding: adding)
                    }
                } else {
                    DispatchQueue.main.async {
                        self.scanFailed("Keine lesbaren Ergebnisse von scan.py erhalten.", adding: adding)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.scanFailed("Fehler beim Starten von scan.py: \(error.localizedDescription)",
                                    adding: adding)
                }
            }
        }
    }

    func scanFinished(_ response: ScanResponse, adding: Bool) {
        isScanning = false
        if adding {
            let known = Set(candidates.map(\.id))
            let added = response.results.filter { !known.contains($0.id) }
            candidates += added
            selectedIds.formUnion(added.filter(\.isRecommended).map(\.id))
            notice = added.isEmpty ? "Nichts Neues, das sich lohnt." : nil
        } else {
            candidates = response.results
            scanSummary = response.summary
            // A single video opened on its own is meant to be worked on, even
            // where the recommendation would leave it unticked.
            selectedIds = response.results.count == 1
                ? Set(response.results.map(\.id))
                : Set(response.results.filter(\.isRecommended).map(\.id))
            currentStep = .candidateSelection
        }
        let backlog = scanBacklog
        scanBacklog = []
        if !backlog.isEmpty {
            open(backlog)
        }
    }

    func scanFailed(_ message: String, adding: Bool) {
        isScanning = false
        if adding {
            notice = message
        } else {
            errorMessage = message
        }
        scanBacklog = []
    }

    /// Whole-batch progress: finished files plus the running files' share.
    var overallFraction: Double {
        let total = max(totalToEncode, 1)
        let finished = completedCount + failedCount
        let running = workers.values
            .filter { $0.status == "running" }
            .reduce(0.0) { $0 + $1.fileFraction }
        return min(1, (Double(finished) + running) / Double(total))
    }

    /// Time left, extrapolated from the time spent so far. Nil until there
    /// is enough progress for the number to mean something.
    func remainingSeconds(at now: Date) -> Double? {
        guard let start = encodeStartedAt, isEncoding else { return nil }
        let elapsed = now.timeIntervalSince(start)
        let fraction = overallFraction
        guard elapsed > 10, fraction > 0.05 else { return nil }
        return elapsed * (1 - fraction) / fraction
    }

    /// Expected wall time for the selection, from past runs; nil when any
    /// selected file's class has no history (a partial number misleads).
    var selectedRuntimeSec: Double? {
        let selection = selectedCandidates
        guard !selection.isEmpty else { return nil }
        let times = selection.compactMap { c in c.estimated_runtime_sec.map { $0 * keptFraction(c) } }
        guard times.count == selection.count else { return nil }
        let parallel = Double(min(max(scanSummary?.parallel_workers ?? 1, 1), selection.count))
        return max(times.max() ?? 0, times.reduce(0, +) / parallel)
    }

    var selectedCandidates: [Candidate] {
        candidates.filter { selectedIds.contains($0.id) }
    }

    var selectedTotalMB: Double {
        selectedCandidates.reduce(0.0) { $0 + $1.size_mb }
    }

    /// Follows the 1080p switch: with it on, downscalable files count with
    /// their downscaled estimate.
    /// The one selected video, when the selection allows trimming.
    var trimTarget: Candidate? {
        let selection = selectedCandidates
        guard selection.count == 1, let c = selection.first, (c.duration_sec ?? 0) > 1 else { return nil }
        return c
    }

    var isTrimmed: Bool {
        // Only once the options page has set the range up for this video.
        guard let c = trimTarget, c.id == trimId, let duration = c.duration_sec else { return false }
        return trimStart > 0.05 || trimEnd < duration - 0.05
    }

    /// Share of a file the encode keeps: all of it, unless trimmed.
    private func keptFraction(_ c: Candidate) -> Double {
        guard isTrimmed, c.id == trimTarget?.id, let duration = c.duration_sec, duration > 0 else { return 1 }
        return max(0, min(1, (trimEnd - trimStart) / duration))
    }

    /// Expected size of one file's result, with downscale and trim.
    private func estimatedAfterMB(_ c: Candidate) -> Double {
        let pct = scaleTo1080p ? (c.estimated_saved_pct_1080 ?? c.estimated_saved_pct)
                               : c.estimated_saved_pct
        return c.size_mb * keptFraction(c) * (1 - pct / 100)
    }

    /// Follows the 1080p switch and the trim.
    var selectedEstimatedSavedMB: Double {
        selectedCandidates.reduce(0.0) { sum, c in sum + (c.size_mb - estimatedAfterMB(c)) }
    }

    /// What switching the 1080p downscale on adds to the selection's saving.
    var downscaleExtraSavedMB: Double {
        selectedCandidates.reduce(0.0) { sum, c in
            sum + max(0, (c.estimated_saved_mb_1080 ?? c.estimated_saved_mb) - c.estimated_saved_mb)
        }
    }

    var selectedTotalAfterMB: Double {
        selectedCandidates.reduce(0.0) { $0 + estimatedAfterMB($1) }
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

    var recommendedIds: Set<String> {
        Set(candidates.filter(\.isRecommended).map(\.id))
    }

    func selectRecommended() {
        selectedIds = recommendedIds
    }

    /// Not ticked because they only pay off downscaled to 1080p.
    var downscaleOnlyUnselected: [Candidate] {
        candidates.filter { $0.recommended_1080 == true && !selectedIds.contains($0.id) }
    }

    /// Selected files that are worth it only with the downscale on.
    var selectedNeedingDownscale: Int {
        selectedCandidates.filter { $0.recommended_1080 == true }.count
    }

    /// Takes the downscale-only files along and turns the downscale on.
    func takeDownscaleOnly() {
        selectedIds.formUnion(downscaleOnlyUnselected.map(\.id))
        scaleTo1080p = true
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
        // A different single video starts untrimmed.
        if let c = trimTarget, c.id != trimId {
            trimId = c.id
            trimStart = 0
            trimEnd = c.duration_sec ?? 0
        }
        currentStep = .options
    }

    func backToCandidates() {
        currentStep = .candidateSelection
    }

    func startEncoding() {
        guard !selectedIds.isEmpty else { return }
        if isGif {
            startGif()
            return
        }
        beginRun(total: selectedIds.count)

        let toProcess = selectedCandidates.map { $0.file_path }
        let tempDir = FileManager.default.temporaryDirectory
        let resultJsonPath = tempDir.appendingPathComponent("videocrunch_batch_\(UUID().uuidString).json").path
        // One path per line: --files splits on commas, and names contain them.
        let fileListURL = tempDir.appendingPathComponent("videocrunch_files_\(UUID().uuidString).txt")
        do {
            try toProcess.map { $0 + "\n" }.joined().write(to: fileListURL, atomically: true, encoding: .utf8)
        } catch {
            isEncoding = false
            errorMessage = "Dateiliste konnte nicht geschrieben werden: \(error.localizedDescription)"
            return
        }

        // Trimming never replaces the original (videocrunch keeps it anyway).
        let trim = isTrimmed ? (start: trimStart, end: trimEnd) : nil
        lastRunTrim = trim.flatMap { t in trimTarget.map { (path: $0.file_path, start: t.start) } }

        var args = [
            scriptDir.appendingPathComponent("batch.py").path,
            "--files-from", fileListURL.path,
            "--audio-mode", audioMode,
            "--codec", targetCodec,
            "--json-out", resultJsonPath,
            "--events"
        ]
        if scaleTo1080p {
            args.append(contentsOf: ["--scale-height", "1080"])
        }
        if moveToTrash && !isTrimmed {
            args.append("--replace")
        }
        if let trim {
            args.append(contentsOf: ["--ss", String(format: "%.3f", trim.start),
                                     "--to", String(format: "%.3f", trim.end)])
        }
        if let floor = minSSIMOverride {
            args.append(contentsOf: ["--min-ssim", String(floor)])
        }

        launchWithEvents(args, script: "batch.py", resultPath: resultJsonPath) { data in
            try? FileManager.default.removeItem(at: fileListURL)
            self.finishBatch(report: data.flatMap { try? JSONDecoder().decode(BatchReport.self, from: $0) })
        }
    }

    /// Clears the encode page for a run of `total` files.
    private func beginRun(total: Int) {
        currentStep = .encoding
        isEncoding = true
        logs = []
        workers = [:]
        batchProgress = BatchProgress()
        completedCount = 0
        failedCount = 0
        totalToEncode = total
        wasCancelled = false
        encodeStartedAt = Date()
        DockProgress.show(0)
        batchResults = []
        gifResult = nil
        suggestedFloor = nil
        retryEligibleCandidates = []
    }

    /// Runs a script that speaks batch.py's --events, feeding the encode
    /// page; `finish` gets its --json-out file once it exits (nil if none).
    private func launchWithEvents(_ args: [String], script: String, resultPath: String,
                                  finish: @escaping (Data?) -> Void) {
        let python = resolvePythonPath()
        DispatchQueue.global(qos: .userInitiated).async {
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
                let data = try? Data(contentsOf: URL(fileURLWithPath: resultPath))
                try? FileManager.default.removeItem(atPath: resultPath)
                DispatchQueue.main.async {
                    self.isEncoding = false
                    self.currentProcess = nil
                    finish(data)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isEncoding = false
                    self.errorMessage = "Fehler beim Ausführen von \(script): \(error.localizedDescription)"
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

    func parseBatchOutput(_ lines: [String]) {
        defer { DockProgress.show(isEncoding ? overallFraction : nil) }
        for line in lines {
            guard let event = BatchEvent.decode(line) else {
                // Anything else is a message (a traceback, a warning): keep it.
                logs.append(line)
                if logs.count > 100 { logs.removeFirst() }
                continue
            }
            batchProgress.apply(event)
        }
        workers = batchProgress.workers
        completedCount = batchProgress.completed
        failedCount = batchProgress.failed
    }

    private func finishBatch(report: BatchReport?) {
        self.batchResults = report?.results ?? []
        self.actualSavedBytes = self.batchResults.reduce(0) { $0 + ($1.saved_bytes ?? 0) }
        // The report is final: it also knows a file the events never
        // finished (batch.py killed mid-run).
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

        DockProgress.show(nil)
        Notifier.notify(
            title: wasCancelled ? "VideoCrunch abgebrochen" : "VideoCrunch fertig",
            body: "\(completedCount) von \(totalToEncode) Videos optimiert, \(formatBytes(actualSavedBytes)) gespart."
        )
    }

    func retryFailedWithNewFloor() {
        guard let floor = suggestedFloor else { return }
        self.minSSIMOverride = floor
        self.selectedIds = Set(retryEligibleCandidates.map { $0.id })
        self.startEncoding()
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

    // MARK: - GIF

    /// GIF mode is on and there is one video to make it from.
    var isGif: Bool {
        outputMode == .gif && trimTarget != nil
    }

    /// The part of the video the GIF shows: the trim, set up on the options page.
    var gifRange: (start: Double, end: Double)? {
        guard let c = trimTarget, let duration = c.duration_sec else { return nil }
        return c.id == trimId ? (trimStart, trimEnd) : (0, duration)
    }

    /// Changes whenever the expected GIF size would.
    var gifEstimateKey: String {
        guard isGif, let range = gifRange else { return "" }
        return String(format: "%d-%d-%.0f-%.2f-%.2f", gifWidth, gifFPS, gifQuality, range.start, range.end)
    }

    private func gifArguments(for c: Candidate, range: (start: Double, end: Double)) -> [String] {
        [scriptDir.appendingPathComponent("gif.py").path, c.file_path,
         "--ss", String(format: "%.3f", range.start), "--to", String(format: "%.3f", range.end),
         "--width", String(gifWidth), "--fps", String(gifFPS), "--quality", String(Int(gifQuality))]
    }

    /// Re-estimates the GIF size half a second after the last change — the
    /// trim handles fire on every pixel they move.
    func requestGifEstimate() {
        estimateWork?.cancel()
        estimateGeneration += 1
        guard isGif, let c = trimTarget, let range = gifRange, range.end > range.start else {
            gifEstimate = nil
            isEstimatingGif = false
            return
        }
        let generation = estimateGeneration
        let args = gifArguments(for: c, range: range) + ["--estimate"]
        let python = resolvePythonPath()
        isEstimatingGif = true
        let work = DispatchWorkItem {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: python)
            proc.arguments = args
            proc.environment = WizardViewModel.toolEnvironment()
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            var estimate: GifEstimate?
            if (try? proc.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                estimate = try? JSONDecoder().decode(GifEstimate.self, from: data)
            }
            DispatchQueue.main.async {
                guard generation == self.estimateGeneration else { return }
                self.gifEstimate = estimate
                self.isEstimatingGif = false
            }
        }
        estimateWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func startGif() {
        guard let c = trimTarget, let range = gifRange else { return }
        beginRun(total: 1)
        lastRunTrim = nil
        let resultPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("videocrunch_gif_\(UUID().uuidString).json").path
        let args = gifArguments(for: c, range: range) + ["--json-out", resultPath, "--events"]
        launchWithEvents(args, script: "gif.py", resultPath: resultPath) { data in
            self.finishGif(data.flatMap { try? JSONDecoder().decode(GifResult.self, from: $0) })
        }
    }

    private func finishGif(_ result: GifResult?) {
        gifResult = result ?? GifResult(status: wasCancelled ? "cancelled" : "failed",
                                        output_path: nil, size_bytes: nil, width: nil, height: nil,
                                        frames: nil, reason: wasCancelled ? "Abgebrochen" : "gif.py lieferte kein Ergebnis",
                                        encoder: nil)
        completedCount = gifResult?.isSuccess == true ? 1 : 0
        failedCount = 1 - completedCount
        currentStep = .completed
        DockProgress.show(nil)
        if let result, result.isSuccess, let path = result.output_path {
            Notifier.notify(title: "GIF fertig",
                            body: "\(URL(fileURLWithPath: path).lastPathComponent), \(formatBytes(result.size_bytes ?? 0))")
        }
    }

    // MARK: - Preview

    /// The file a preview is being made for, while it runs.
    @Published var previewingId: String?
    @Published var previewError: String?

    /// Encodes the hardest few seconds of `candidate` with the current
    /// settings (videocrunch.py --preview) and hands back what to compare.
    func makePreview(for candidate: Candidate, completion: @escaping (Comparison) -> Void) {
        guard previewingId == nil else { return }
        previewingId = candidate.id
        previewError = nil
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("videocrunch-preview-\(UUID().uuidString)")
        var args = [scriptDir.appendingPathComponent("videocrunch.py").path, candidate.file_path,
                    "--preview", dir.path, "--audio-mode", audioMode, "--codec", targetCodec]
        if scaleTo1080p && candidate.canDownscale {
            args += ["--scale-height", "1080"]
        }
        if isTrimmed, candidate.id == trimTarget?.id {
            args += ["--ss", String(format: "%.3f", trimStart), "--to", String(format: "%.3f", trimEnd)]
        }
        if let floor = minSSIMOverride {
            args += ["--min-ssim", String(floor)]
        }
        let python = resolvePythonPath()
        let name = candidate.filename

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: python)
            proc.arguments = args
            proc.environment = WizardViewModel.toolEnvironment()
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            var result: PreviewResult?
            if (try? proc.run()) != nil {
                proc.waitUntilExit()
                if let data = try? Data(contentsOf: dir.appendingPathComponent("preview.json")) {
                    result = try? JSONDecoder().decode(PreviewResult.self, from: data)
                }
            }
            DispatchQueue.main.async {
                self.previewingId = nil
                guard let result else {
                    self.previewError = "Vorschau für \(name) ging nicht."
                    return
                }
                let verdict = result.meets_target ? "erfüllt das Qualitätsziel"
                                                  : "unter dem Qualitätsziel"
                completion(Comparison(
                    source: URL(fileURLWithPath: result.source),
                    encoded: URL(fileURLWithPath: result.preview),
                    title: "Vorschau: \(name)",
                    note: String(format: "Schwierigste Stelle · Q %d · SSIM %.3f · %@ · ca. −%.0f %%",
                                 result.quality, result.ssim, verdict, result.saved_pct)))
            }
        }
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
