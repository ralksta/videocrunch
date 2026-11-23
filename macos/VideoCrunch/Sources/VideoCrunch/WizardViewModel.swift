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
    /// Target short-side pixels (`0` keeps the original resolution).
    @Published var scaleHeight: Int = 0
    /// Compatibility wrapper for the legacy 1080p toggle and quick-action helpers.
    var scaleTo1080p: Bool {
        get { scaleHeight == 1080 }
        set { scaleHeight = newValue ? 1080 : 0 }
    }
    /// 48–60 fps footage at half the rate (slow motion is never touched).
    @Published var halveFrameRate: Bool = false
    /// Letterbox/pillarbox bars cut away, where the encode finds any.
    @Published var cropBars: Bool = false
    /// 0: the quality search decides the size. Otherwise every video comes
    /// in under this many MB (fit.py), for a mail or a chat.
    @Published var sizeLimitMB: Int = 0
    /// Quality vs. compression balance when encoding in quality mode (`sizeLimitMB == 0`).
    @Published var qualityBalance: QualityBalance = .balanced
    /// Fixed MB presets offered in size-limit mode.
    static let sizePresets = [10, 25, 50, 100]
    /// The limit the last run had, for the last page's wording.
    @Published var lastRunSizeLimitMB: Int = 0
    @Published var moveToTrash: Bool = false
    @Published var minSSIMOverride: Double? = nil

    /// Explicit retry floor overrides the balance preset's SSIM target.
    var effectiveMinSSIM: Double? {
        minSSIMOverride ?? qualityBalance.minSSIM
    }
    /// Trim for a single selected video, in seconds of the source.
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    private var trimId: String?
    /// Video re-encode or GIF; the GIF needs the single video the trim is for.
    @Published var outputMode: OutputMode = .video
    @Published var customPresets: [EncodePreset] = []
    @Published var mergeOrder: [String] = []
    @Published var lastRunWasMerge: Bool = false
    @Published var lastRunWasTrimOnly: Bool = false
    @Published var lastRunMergeClipCount: Int = 0
    @Published var lifetimeStats = LifetimeStats(totalSavedBytes: 0, encodedCount: 0)
    @Published var recentEncodes: [RecentEncodeEntry] = []
    @Published var gifWidth: Int = 480
    @Published var gifFPS: Int = 15
    @Published var gifQuality: Double = 90
    /// Playback speed: 0.5 slow motion, 2 twice as fast.
    @Published var gifSpeed: Double = 1
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
    @Published var completedFiles: [CompletedWorkerItem] = []
    @Published var liveSavedBytes: Int64 = 0
    private var batchProgress = BatchProgress()
    @Published var completedCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var totalToEncode: Int = 0
    @Published var logs: [String] = []
    @Published var isEncoding: Bool = false
    @Published var wasCancelled: Bool = false
    @Published var encodeStartedAt: Date? = nil

    // Step 2: Candidate selection focus
    @Published var focusedCandidateId: String? = nil

    // Step 5: Completed
    @Published var batchResults: [BatchItemResult] = []
    @Published var actualSavedBytes: Int64 = 0
    @Published var retryEligibleCandidates: [Candidate] = []
    @Published var suggestedFloor: Double? = nil

    // Preferences
    @Published var appLanguage: String = "" {
        didSet {
            guard !isApplyingPersistedPrefs else { return }
            L10n.languageOverride = appLanguage.isEmpty ? nil : appLanguage
            defaults?.set(appLanguage, forKey: Self.appLanguageKey)
        }
    }
    @Published var notificationsEnabled: Bool = true {
        didSet {
            guard !isApplyingPersistedPrefs else { return }
            Notifier.isEnabled = notificationsEnabled
            defaults?.set(notificationsEnabled, forKey: Self.notificationsEnabledKey)
        }
    }
    @Published var hapticsEnabled: Bool = true {
        didSet {
            guard !isApplyingPersistedPrefs else { return }
            Haptics.isEnabled = hapticsEnabled
            defaults?.set(hapticsEnabled, forKey: Self.hapticsEnabledKey)
        }
    }
    @Published var customOutputFolder: URL? = nil
    @Published var grantedFolderCount: Int = 0
    private var isApplyingPersistedPrefs = false
    private var pendingSandboxedReplace = false

    // Media Inspector
    struct InspectedTarget: Identifiable {
        let url: URL
        var id: String { url.path }
    }
    @Published var inspectedTarget: InspectedTarget? = nil
    @Published var inspection: MediaInspection? = nil
    @Published var isInspecting: Bool = false
    @Published var inspectionError: String? = nil
    private var inspectGeneration = 0

    private var currentProcess: Process?
    private let defaults: UserDefaults?
    let sandboxAccess: SandboxAccessManager
    private static let customPresetsKey = "videocrunch.customPresets"
    private static let lastSettingsKey = "videocrunch.lastSettings"
    private static let appLanguageKey = "videocrunch.appLanguage"
    private static let notificationsEnabledKey = "videocrunch.notificationsEnabled"
    private static let hapticsEnabledKey = "videocrunch.hapticsEnabled"
    var scriptDir: URL
    /// Replaces the scan.py run when set — tests feed `scanFinished` directly.
    var scanner: ((_ urls: [URL], _ adding: Bool) -> Void)?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        self.sandboxAccess = SandboxAccessManager(defaults: defaults)
        self.scriptDir = AppRuntime.resolveScriptDir()
        self.customOutputFolder = sandboxAccess.customOutputFolderURL
        self.grantedFolderCount = sandboxAccess.grantedFolderCount
        loadPersistedState()
    }

    func setRepoPath(_ path: String) {
        self.scriptDir = URL(fileURLWithPath: path)
    }

    func chooseCustomOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = L("settings.output.title")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let existing = customOutputFolder {
            panel.directoryURL = existing
        }
        if panel.runModal() == .OK, let url = panel.url {
            sandboxAccess.setCustomOutputFolder(url)
            customOutputFolder = sandboxAccess.customOutputFolderURL
        }
    }

    func clearCustomOutputFolder() {
        sandboxAccess.setCustomOutputFolder(nil)
        customOutputFolder = nil
    }

    func clearGrantedFolders() {
        sandboxAccess.clearGrantedFolders()
        grantedFolderCount = sandboxAccess.grantedFolderCount
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
            for url in panel.urls {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    sandboxAccess.registerGrantedFolder(url)
                }
            }
            grantedFolderCount = sandboxAccess.grantedFolderCount
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
        restoreDefaultOrRememberedSettings()
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
        restoreDefaultOrRememberedSettings()
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
                    let errStr = WizardViewModel.lastMessage(errData) ?? L("vm.scan_failed")
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
                        self.scanFailed(L("vm.scan_unreadable"), adding: adding)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.scanFailed(L("vm.scan_start_error_fmt", error.localizedDescription),
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
            notice = added.isEmpty ? L("vm.nothing_new") : nil
        } else {
            candidates = response.results
            scanSummary = response.summary
            focusedCandidateId = nil
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
        if isTrimOnly { return nil }
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

    /// Trim-only mode (stream copy passthrough without re-encoding).
    var isTrimOnly: Bool {
        outputMode == .trimOnly && trimTarget != nil
    }

    /// Largest short-side resolution (in pixels) among the selected videos.
    var maxSelectedShortSide: Int {
        selectedCandidates.map(\.shortSide).max() ?? 0
    }

    /// Menu label for keeping the original resolution (`scaleHeight == 0`).
    var originalResolutionLabel: String {
        if selectedCandidates.count == 1, let dims = selectedCandidates[0].dimensionsString {
            return L("options.resolution.original_dims_fmt", dims)
        }
        return L("options.resolution.keep_original")
    }

    /// True when every selected video with known dimensions is vertical (portrait).
    var isSelectionPortrait: Bool {
        let known = selectedCandidates.filter { $0.width > 0 && $0.height > 0 }
        return !known.isEmpty && known.allSatisfy(\.isPortrait)
    }

    /// Menu label for a resolution preset, flipping W×H when the selection is portrait.
    func resolutionPresetLabel(_ preset: ResolutionPreset) -> String {
        preset.label(portrait: isSelectionPortrait)
    }

    /// Downscaling to `targetHeight` only applies when at least one selected video is larger.
    func canDownscale(to targetHeight: Int) -> Bool {
        guard !selectedCandidates.isEmpty else { return true }
        return maxSelectedShortSide > targetHeight
    }

    /// Largest effective source size (in MB) among the selected videos.
    var maxSelectedVideoMB: Double {
        selectedCandidates.map { $0.size_mb * keptFraction($0) }.max() ?? 0
    }

    /// A size preset only shrinks if at least one selected video is larger than `mb`.
    func isSizeLimitUseful(_ mb: Int) -> Bool {
        guard !selectedCandidates.isEmpty else { return true }
        return maxSelectedVideoMB > Double(mb)
    }

    /// Largest preset that actually shrinks the selection (e.g. 25 MB for a 41 MB video).
    func defaultSizeLimitMB() -> Int {
        Self.sizePresets.last { isSizeLimitUseful($0) } ?? Self.sizePresets[0]
    }

    /// Two-way switch between quality mode (`0`) and a fixed MB ceiling (`> 0`).
    var isSizeLimitMode: Bool {
        get { sizeLimitMB > 0 }
        set {
            if newValue {
                if sizeLimitMB == 0 || !isSizeLimitUseful(sizeLimitMB) {
                    sizeLimitMB = defaultSizeLimitMB()
                }
            } else {
                sizeLimitMB = 0
            }
        }
    }

    /// Baseline saved percentage before applying `qualityBalance`, factoring in `scaleHeight`.
    private func baseSavedPct(_ c: Candidate) -> Double {
        let short = c.shortSide
        guard scaleHeight > 0, short > 0, scaleHeight < short else {
            return c.estimated_saved_pct
        }
        if scaleHeight == 1080 {
            return c.estimated_saved_pct_1080 ?? c.estimated_saved_pct
        }
        if let p1080 = c.estimated_saved_pct_1080, short > 1080 {
            if scaleHeight > 1080 {
                let t = Double(short - scaleHeight) / Double(short - 1080)
                return c.estimated_saved_pct + (p1080 - c.estimated_saved_pct) * t
            }
            let rem1080 = max(0, 1.0 - p1080 / 100.0)
            return (1.0 - rem1080 * (Double(scaleHeight) / 1080.0)) * 100.0
        }
        let rem = max(0, 1.0 - c.estimated_saved_pct / 100.0)
        return (1.0 - rem * (Double(scaleHeight) / Double(short))) * 100.0
    }

    /// Live projected output size (MB) of one candidate under the current options.
    func estimatedAfterMB(for c: Candidate) -> Double {
        estimatedAfterMB(c, halving: nil)
    }

    /// Expected size of one file's result, with downscale, frame rate and trim.
    private func estimatedAfterMB(_ c: Candidate, halving: Bool? = nil) -> Double {
        if isTrimOnly {
            return c.size_mb * keptFraction(c)
        }
        if sizeLimitMB > 0 {
            // What fits, or the file as it is when it already does.
            return min(c.size_mb * keptFraction(c), Double(sizeLimitMB))
        }
        let pct = min(90, max(0, baseSavedPct(c) * qualityBalance.savingsFactor))
        let rate = (halving ?? halveFrameRate) ? (c.half_fps_size_factor ?? 1) : 1
        return c.size_mb * keptFraction(c) * (1 - pct / 100) * rate
    }

    /// Some of the selection is 48–60 fps.
    var canHalveFrameRate: Bool {
        selectedCandidates.contains { $0.half_fps_size_factor != nil }
    }

    /// What halving the frame rate adds to the saving, with the other settings as they are.
    var halfFrameRateExtraSavedMB: Double {
        selectedCandidates.reduce(0.0) { sum, c in
            sum + estimatedAfterMB(c, halving: false) - estimatedAfterMB(c, halving: true)
        }
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

    var skippedCount: Int {
        batchResults.filter { $0.status == "skipped" }.count
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
        let selectedSet = Set(selectedCandidates.map(\.id))
        mergeOrder = mergeOrder.filter { selectedSet.contains($0) }
            + selectedCandidates.map(\.id).filter { !mergeOrder.contains($0) }
        if trimTarget == nil && (outputMode == .trimOnly || outputMode == .gif) {
            outputMode = .video
        }
        if outputMode == .merge && !canMerge {
            outputMode = .video
        }
        currentStep = .options
    }

    // MARK: - Presets & Persisted Settings

    var allPresets: [EncodePreset] {
        EncodePreset.builtIn + customPresets
    }

    var matchingPreset: EncodePreset? {
        allPresets.first {
            $0.matches(codec: targetCodec, balance: qualityBalance, sizeLimitMB: sizeLimitMB,
                       scaleHeight: scaleHeight, audioMode: audioMode,
                       halveFrameRate: halveFrameRate, cropBars: cropBars, moveToTrash: moveToTrash)
        }
    }

    func applyPreset(_ preset: EncodePreset) {
        Haptics.tap(.generic)
        targetCodec = preset.targetCodec
        qualityBalance = QualityBalance(rawValue: preset.qualityBalance) ?? .balanced
        sizeLimitMB = preset.sizeLimitMB
        scaleHeight = preset.scaleHeight
        audioMode = preset.audioMode
        halveFrameRate = preset.halveFrameRate
        cropBars = preset.cropBars
        moveToTrash = preset.moveToTrash
        persistCurrentSettings()
    }

    func saveCurrentAsPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = currentSettingsSnapshot(id: "custom.\(UUID().uuidString)", name: trimmed, isBuiltIn: false)
        if let existing = customPresets.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            customPresets[existing] = EncodePreset(
                id: customPresets[existing].id, name: trimmed, isBuiltIn: false,
                targetCodec: preset.targetCodec, qualityBalance: preset.qualityBalance,
                sizeLimitMB: preset.sizeLimitMB, scaleHeight: preset.scaleHeight,
                audioMode: preset.audioMode, halveFrameRate: preset.halveFrameRate,
                cropBars: preset.cropBars, moveToTrash: preset.moveToTrash
            )
        } else {
            customPresets.append(preset)
        }
        persistCustomPresets()
        persistCurrentSettings()
    }

    func deleteCustomPreset(id: String) {
        customPresets.removeAll { $0.id == id }
        persistCustomPresets()
    }

    func resetSettingsToDefaults() {
        applyPreset(EncodePreset.builtIn[0])
    }

    func persistCurrentSettings() {
        guard let defaults else { return }
        let snapshot = currentSettingsSnapshot(id: "last", name: "Zuletzt", isBuiltIn: false)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.lastSettingsKey)
        }
    }

    private func currentSettingsSnapshot(id: String, name: String, isBuiltIn: Bool) -> EncodePreset {
        EncodePreset(
            id: id, name: name, isBuiltIn: isBuiltIn,
            targetCodec: targetCodec, qualityBalance: qualityBalance.rawValue,
            sizeLimitMB: sizeLimitMB, scaleHeight: scaleHeight,
            audioMode: audioMode, halveFrameRate: halveFrameRate,
            cropBars: cropBars, moveToTrash: moveToTrash
        )
    }

    private func persistCustomPresets() {
        guard let defaults, let data = try? JSONEncoder().encode(customPresets) else { return }
        defaults.set(data, forKey: Self.customPresetsKey)
    }

    private func loadPersistedState() {
        guard let defaults else { return }
        isApplyingPersistedPrefs = true
        let savedLang = defaults.string(forKey: Self.appLanguageKey) ?? ""
        appLanguage = savedLang
        L10n.languageOverride = savedLang.isEmpty ? nil : savedLang

        let savedNotif = defaults.object(forKey: Self.notificationsEnabledKey) as? Bool ?? true
        notificationsEnabled = savedNotif
        Notifier.isEnabled = savedNotif

        let savedHaptics = defaults.object(forKey: Self.hapticsEnabledKey) as? Bool ?? true
        hapticsEnabled = savedHaptics
        Haptics.isEnabled = savedHaptics
        isApplyingPersistedPrefs = false

        if let data = defaults.data(forKey: Self.customPresetsKey),
           let saved = try? JSONDecoder().decode([EncodePreset].self, from: data) {
            customPresets = saved
        }
        if let data = defaults.data(forKey: Self.lastSettingsKey),
           let last = try? JSONDecoder().decode(EncodePreset.self, from: data) {
            applyPreset(last)
        }
        refreshLifetimeStats()
    }

    func resetLocalStats() {
        LifetimeStats.resetExtra(defaults: defaults)
        refreshLifetimeStats()
    }

    var canGoBack: Bool {
        switch currentStep {
        case .options, .candidateSelection: return true
        case .scanning: return errorMessage != nil
        default: return false
        }
    }

    func goBack() {
        switch currentStep {
        case .options: backToCandidates()
        case .candidateSelection, .scanning: startOver()
        default: break
        }
    }

    var primaryInspectableURL: URL? {
        switch currentStep {
        case .candidateSelection:
            let id = focusedCandidateId ?? selectedCandidates.first?.id ?? candidates.first?.id
            return id.map { URL(fileURLWithPath: $0) }
        case .options:
            guard let target = trimTarget ?? selectedCandidates.first else { return nil }
            return URL(fileURLWithPath: target.file_path)
        case .encoding:
            let path = workers.values.first(where: { $0.status == "running" })?.path
                ?? selectedCandidates.first?.file_path
            return path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        case .completed:
            let path = batchResults.first(where: { $0.status == "success" })?.path ?? batchResults.first?.path
            return path.map { URL(fileURLWithPath: $0) }
        case .scanning:
            return targetURLs.first
        }
    }

    func inspectPrimary() {
        guard let url = primaryInspectableURL else { return }
        inspect(url)
    }

    var revealableURLs: [URL] {
        if currentStep == .completed {
            if let gif = gifResult?.output_path, FileManager.default.fileExists(atPath: gif) {
                return [URL(fileURLWithPath: gif)]
            }
            let encoded = batchResults
                .filter { $0.status == "success" }
                .compactMap(\.output_path)
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) }
            if !encoded.isEmpty { return encoded }
        }
        if let inspectable = primaryInspectableURL, FileManager.default.fileExists(atPath: inspectable.path) {
            return [inspectable]
        }
        return targetURLs
    }

    func revealCurrentInFinder() {
        let urls = revealableURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func refreshLifetimeStats() {
        guard defaults != nil else { return }
        lifetimeStats = LifetimeStats.load(defaults: defaults)
        recentEncodes = LifetimeStats.loadRecent(limit: 3)
    }

    private func restoreDefaultOrRememberedSettings() {
        minSSIMOverride = nil
        if let defaults,
           let data = defaults.data(forKey: Self.lastSettingsKey),
           let last = try? JSONDecoder().decode(EncodePreset.self, from: data) {
            targetCodec = last.targetCodec
            qualityBalance = QualityBalance(rawValue: last.qualityBalance) ?? .balanced
            sizeLimitMB = last.sizeLimitMB
            scaleHeight = last.scaleHeight
            audioMode = last.audioMode
            halveFrameRate = last.halveFrameRate
            cropBars = last.cropBars
            moveToTrash = last.moveToTrash
        } else {
            scaleHeight = 0
            qualityBalance = .balanced
        }
    }

    // MARK: - Lossless Concat Merge

    var orderedMergeCandidates: [Candidate] {
        let byId = Dictionary(uniqueKeysWithValues: selectedCandidates.map { ($0.id, $0) })
        var seen = Set<String>()
        var ordered: [Candidate] = []
        for id in mergeOrder {
            if let c = byId[id], seen.insert(id).inserted {
                ordered.append(c)
            }
        }
        for c in selectedCandidates where seen.insert(c.id).inserted {
            ordered.append(c)
        }
        return ordered
    }

    var mergeIncompatibilityReason: String? {
        let items = selectedCandidates
        guard items.count >= 2 else {
            return L("vm.merge.need_two")
        }
        let codecs = Set(items.map { $0.codec.lowercased() }.filter { !$0.isEmpty })
        if codecs.count > 1 || codecs.isEmpty {
            let names = codecs.map { $0.uppercased() }.sorted().joined(separator: ", ")
            return L("vm.merge.diff_codecs_fmt", names.isEmpty ? L("vm.merge.unknown") : names)
        }
        let dims = Set(items.map { "\($0.width)×\($0.height)" })
        if dims.count > 1 || items.contains(where: { $0.width <= 0 || $0.height <= 0 }) {
            return L("vm.merge.diff_resolutions_fmt", dims.sorted().joined(separator: ", "))
        }
        return nil
    }

    var canMerge: Bool { mergeIncompatibilityReason == nil }
    var isMerge: Bool { outputMode == .merge && canMerge }

    func moveMergeClip(id: String, offset: Int) {
        var order = orderedMergeCandidates.map(\.id)
        guard let idx = order.firstIndex(of: id) else { return }
        let target = idx + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(idx, target)
        mergeOrder = order
    }

    func backToCandidates() {
        currentStep = .candidateSelection
    }

    func startEncoding() {
        guard !selectedIds.isEmpty else { return }
        lastRunWasMerge = false
        lastRunWasTrimOnly = false
        if isGif {
            startGif()
            return
        }
        if isMerge {
            startMerge()
            return
        }
        let targetDirs = customOutputFolder.map { [$0] }
            ?? selectedCandidates.map { URL(fileURLWithPath: $0.file_path).deletingLastPathComponent() }
        if AppRuntime.isSandboxed {
            guard sandboxAccess.ensureWriteAccess(for: targetDirs) else {
                grantedFolderCount = sandboxAccess.grantedFolderCount
                return
            }
            grantedFolderCount = sandboxAccess.grantedFolderCount
        }
        lastRunWasTrimOnly = isTrimOnly
        if !isTrimOnly {
            persistCurrentSettings()
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
            errorMessage = L("vm.run.file_list_error_fmt", error.localizedDescription)
            return
        }

        // Trimming never replaces the original (videocrunch keeps it anyway).
        let trim = isTrimmed ? (start: trimStart, end: trimEnd) : nil
        lastRunTrim = trim.flatMap { t in trimTarget.map { (path: $0.file_path, start: t.start) } }

        lastRunSizeLimitMB = sizeLimitMB
        if sizeLimitMB > 0 && !isTrimOnly {
            // Under a size: fit.py picks bitrate and resolution itself.
            var args = [
                scriptDir.appendingPathComponent("fit.py").path,
                "--files-from", fileListURL.path,
                "--max-mb", String(sizeLimitMB),
                "--codec", targetCodec,
                "--json-out", resultJsonPath,
                "--events"
            ] + editArguments
            if let outDir = customOutputFolder {
                args.append(contentsOf: ["--output-dir", outDir.path])
            }
            if let trim {
                args.append(contentsOf: ["--ss", String(format: "%.3f", trim.start),
                                         "--to", String(format: "%.3f", trim.end)])
            }
            launchWithEvents(args, script: "fit.py", resultPath: resultJsonPath) { data in
                try? FileManager.default.removeItem(at: fileListURL)
                self.finishBatch(report: data.flatMap { try? JSONDecoder().decode(BatchReport.self, from: $0) })
            }
            return
        }

        var args = [
            scriptDir.appendingPathComponent("batch.py").path,
            "--files-from", fileListURL.path,
            "--codec", targetCodec,
            "--json-out", resultJsonPath,
            "--events"
        ] + editArguments
        if let outDir = customOutputFolder {
            args.append(contentsOf: ["--output-dir", outDir.path])
        }
        if isTrimOnly {
            args.append(contentsOf: ["--video-mode", "copy"])
        } else {
            if scaleHeight > 0 {
                args.append(contentsOf: ["--scale-height", String(scaleHeight)])
            }
            if let floor = effectiveMinSSIM {
                args.append(contentsOf: ["--min-ssim", String(floor)])
            }
        }
        if moveToTrash && !isTrimmed && !isTrimOnly && customOutputFolder == nil {
            if AppRuntime.isSandboxed {
                pendingSandboxedReplace = true
            } else {
                args.append("--replace")
            }
        }
        if let trim {
            args.append(contentsOf: ["--ss", String(format: "%.3f", trim.start),
                                     "--to", String(format: "%.3f", trim.end)])
        }

        launchWithEvents(args, script: "batch.py", resultPath: resultJsonPath) { data in
            try? FileManager.default.removeItem(at: fileListURL)
            self.finishBatch(report: data.flatMap { try? JSONDecoder().decode(BatchReport.self, from: $0) })
        }
    }

    private func startMerge() {
        let clips = orderedMergeCandidates
        guard clips.count >= 2 else { return }
        let targetDirs = customOutputFolder.map { [$0] }
            ?? clips.prefix(1).map { URL(fileURLWithPath: $0.file_path).deletingLastPathComponent() }
        if AppRuntime.isSandboxed {
            guard sandboxAccess.ensureWriteAccess(for: targetDirs) else {
                grantedFolderCount = sandboxAccess.grantedFolderCount
                return
            }
            grantedFolderCount = sandboxAccess.grantedFolderCount
        }
        lastRunWasMerge = true
        lastRunWasTrimOnly = false
        lastRunMergeClipCount = clips.count
        lastRunSizeLimitMB = 0
        lastRunTrim = nil
        beginRun(total: 1)

        let tempDir = FileManager.default.temporaryDirectory
        let resultJsonPath = tempDir.appendingPathComponent("videocrunch_merge_\(UUID().uuidString).json").path
        let fileListURL = tempDir.appendingPathComponent("videocrunch_merge_files_\(UUID().uuidString).txt")
        do {
            try clips.map { $0.file_path + "\n" }.joined().write(to: fileListURL, atomically: true, encoding: .utf8)
        } catch {
            isEncoding = false
            errorMessage = L("vm.run.file_list_error_fmt", error.localizedDescription)
            return
        }

        var args = [
            scriptDir.appendingPathComponent("concat.py").path,
            "--files-from", fileListURL.path,
            "--json-out", resultJsonPath,
            "--events",
        ]
        if let outDir = customOutputFolder {
            args.append(contentsOf: ["--output-dir", outDir.path])
        }
        launchWithEvents(args, script: "concat.py", resultPath: resultJsonPath) { data in
            try? FileManager.default.removeItem(at: fileListURL)
            self.finishBatch(report: data.flatMap { try? JSONDecoder().decode(BatchReport.self, from: $0) })
        }
    }

    /// Audio, frame rate and bars, the same for the run and its preview.
    /// "none" is the audio picker's third choice: original sound, left out.
    var editArguments: [String] {
        var args = ["--audio-mode", audioMode == "none" ? "standard" : audioMode]
        if audioMode == "none" { args.append("--no-audio") }
        if halveFrameRate && canHalveFrameRate { args.append("--half-fps") }
        if cropBars { args.append("--crop-bars") }
        return args
    }

    /// Clears the encode page for a run of `total` files.
    private func beginRun(total: Int) {
        pendingSandboxedReplace = false
        currentStep = .encoding
        isEncoding = true
        logs = []
        workers = [:]
        completedFiles = []
        liveSavedBytes = 0
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
        let cmdSummary = "$ " + ([script] + args.dropFirst()).joined(separator: " ")
        logs.append(cmdSummary)
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
                    self.errorMessage = L("vm.run.exec_error_fmt", script, error.localizedDescription)
                }
            }
        }
    }

    func cancelEncoding() {
        wasCancelled = true
        currentProcess?.terminate()
        currentProcess = nil
        isEncoding = false
        logs.append(L("vm.run.cancelled_log"))
    }

    func parseBatchOutput(_ lines: [String]) {
        defer { DockProgress.show(isEncoding ? overallFraction : nil) }
        for line in lines {
            guard let event = BatchEvent.decode(line) else {
                // Anything else is a message (a traceback, a warning): keep it.
                logs.append(line)
                if logs.count > 500 { logs.removeFirst() }
                continue
            }
            batchProgress.apply(event)
        }
        workers = batchProgress.workers
        completedFiles = batchProgress.completedFiles
        liveSavedBytes = batchProgress.liveSavedBytes
        completedCount = batchProgress.completed
        failedCount = batchProgress.failed
    }

    // MARK: - Active Job Metadata for Encode Stage

    func candidate(forPath path: String) -> Candidate? {
        if !path.isEmpty, let match = candidates.first(where: { $0.file_path == path }) {
            return match
        }
        if totalToEncode == 1 {
            return selectedCandidates.first
        }
        return nil
    }

    var activeTargetSummary: String {
        if isGif {
            return L("vm.target.gif_fmt", gifFPS, gifWidth)
        }
        if lastRunWasMerge || isMerge {
            let count = lastRunMergeClipCount > 0 ? lastRunMergeClipCount : orderedMergeCandidates.count
            return L("vm.target.merge_fmt", count)
        }
        if lastRunWasTrimOnly || isTrimOnly {
            return L("vm.target.stream_copy")
        }
        if lastRunSizeLimitMB > 0 || sizeLimitMB > 0 {
            let limit = lastRunSizeLimitMB > 0 ? lastRunSizeLimitMB : sizeLimitMB
            return L("vm.target.size_limit_fmt", limit, targetCodec.uppercased())
        }
        var parts = [targetCodec.uppercased(), qualityBalance.label]
        if scaleHeight > 0 {
            parts.append("\(scaleHeight)p")
        }
        if halveFrameRate && canHalveFrameRate {
            parts.append("30 fps")
        }
        return parts.joined(separator: " · ")
    }

    var activeAudioSummary: String? {
        if isGif || lastRunWasMerge || isMerge {
            return nil
        }
        if lastRunWasTrimOnly || isTrimOnly {
            return L("vm.audio.copy")
        }
        switch audioMode {
        case "enhanced": return L("vm.audio.enhanced")
        case "none": return L("vm.audio.none")
        default: return L("vm.audio.copy")
        }
    }

    private func finishBatch(report: BatchReport?) {
        var results = report?.results ?? []
        let shouldTrashOriginals = pendingSandboxedReplace
        pendingSandboxedReplace = false
        if shouldTrashOriginals && !wasCancelled {
            for i in results.indices {
                guard results[i].status == "success",
                      let srcPath = results[i].path,
                      let outPath = results[i].output_path else { continue }
                let srcURL = URL(fileURLWithPath: srcPath)
                let outURL = URL(fileURLWithPath: outPath)
                if let replaced = SandboxAccessManager.replaceOriginalWithTrash(original: srcURL, encoded: outURL) {
                    results[i].output_path = replaced.path
                }
            }
        }
        self.batchResults = results
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

        if defaults != nil {
            if lastRunSizeLimitMB > 0 || lastRunWasTrimOnly {
                LifetimeStats.recordExtra(savedBytes: actualSavedBytes, count: completedCount, defaults: defaults)
            }
            refreshLifetimeStats()
        }

        if completedCount > 0 && !wasCancelled {
            Haptics.tap(.levelChange)
        }

        DockProgress.show(nil)
        let title = wasCancelled ? L("vm.notify.cancelled_title") : L("vm.notify.done_title")
        let body: String
        if wasCancelled {
            body = L("vm.notify.cancelled_body_fmt", completedCount, totalToEncode)
        } else if lastRunWasTrimOnly && completedCount > 0 {
            body = L("vm.notify.trimmed_body")
        } else if lastRunWasMerge && completedCount > 0 {
            body = L("vm.notify.merged_body")
        } else {
            body = L("vm.notify.done_body_fmt", completedCount, totalToEncode, formatBytes(max(0, actualSavedBytes)))
        }
        Notifier.notify(title: title, body: body)
    }

    func retryFailedWithNewFloor() {
        guard let floor = suggestedFloor else { return }
        self.minSSIMOverride = floor
        self.selectedIds = Set(retryEligibleCandidates.map { $0.id })
        self.startEncoding()
    }

    /// Runtime environment for bundled helpers/Python or dev Homebrew setup.
    nonisolated static func toolEnvironment() -> [String: String] {
        AppRuntime.toolEnvironment()
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
        return String(format: "%d-%d-%.0f-%.2f-%.2f-%.2f", gifWidth, gifFPS, gifQuality, gifSpeed,
                      range.start, range.end)
    }

    private func gifArguments(for c: Candidate, range: (start: Double, end: Double)) -> [String] {
        [scriptDir.appendingPathComponent("gif.py").path, c.file_path,
         "--ss", String(format: "%.3f", range.start), "--to", String(format: "%.3f", range.end),
         "--width", String(gifWidth), "--fps", String(gifFPS), "--quality", String(Int(gifQuality)),
         "--speed", String(gifSpeed)]
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
        let targetDirs = customOutputFolder.map { [$0] }
            ?? [URL(fileURLWithPath: c.file_path).deletingLastPathComponent()]
        if AppRuntime.isSandboxed {
            guard sandboxAccess.ensureWriteAccess(for: targetDirs) else {
                grantedFolderCount = sandboxAccess.grantedFolderCount
                return
            }
            grantedFolderCount = sandboxAccess.grantedFolderCount
        }
        lastRunSizeLimitMB = 0
        beginRun(total: 1)
        lastRunTrim = nil
        let resultPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("videocrunch_gif_\(UUID().uuidString).json").path
        var args = gifArguments(for: c, range: range) + ["--json-out", resultPath, "--events"]
        if let outDir = customOutputFolder {
            args.append(contentsOf: ["--output-dir", outDir.path])
        }
        launchWithEvents(args, script: "gif.py", resultPath: resultPath) { data in
            self.finishGif(data.flatMap { try? JSONDecoder().decode(GifResult.self, from: $0) })
        }
    }

    private func finishGif(_ result: GifResult?) {
        gifResult = result ?? GifResult(status: wasCancelled ? "cancelled" : "failed",
                                        output_path: nil, size_bytes: nil, width: nil, height: nil,
                                        frames: nil, reason: wasCancelled ? L("encoding.cancelled") : L("vm.gif.no_result"),
                                        encoder: nil)
        completedCount = gifResult?.isSuccess == true ? 1 : 0
        failedCount = 1 - completedCount
        currentStep = .completed
        if result?.isSuccess == true {
            Haptics.tap(.levelChange)
        }
        DockProgress.show(nil)
        if let result, result.isSuccess, let path = result.output_path {
            Notifier.notify(title: L("vm.gif.notify_title"),
                            body: L("vm.gif.notify_body_fmt", URL(fileURLWithPath: path).lastPathComponent, formatBytes(result.size_bytes ?? 0)))
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
                    "--preview", dir.path, "--codec", targetCodec] + editArguments
        if scaleHeight > 0 && candidate.shortSide > scaleHeight {
            args += ["--scale-height", String(scaleHeight)]
        }
        if isTrimmed, candidate.id == trimTarget?.id {
            args += ["--ss", String(format: "%.3f", trimStart), "--to", String(format: "%.3f", trimEnd)]
        }
        if let floor = effectiveMinSSIM {
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
                    self.previewError = L("vm.preview.failed_fmt", name)
                    return
                }
                let verdict = result.meets_target ? L("vm.preview.meets_target")
                                                  : L("vm.preview.below_target")
                completion(Comparison(
                    source: URL(fileURLWithPath: result.source),
                    encoded: URL(fileURLWithPath: result.preview),
                    title: L("vm.preview.title_fmt", name),
                    note: L("vm.preview.note_fmt", result.quality, result.ssim, verdict, result.saved_pct)))
            }
        }
    }

    // MARK: - Media Inspector

    func inspect(_ url: URL) {
        inspectGeneration += 1
        let generation = inspectGeneration
        inspectedTarget = InspectedTarget(url: url)
        inspection = nil
        inspectionError = nil
        isInspecting = true

        let python = resolvePythonPath()
        let script = scriptDir.appendingPathComponent("inspect_media.py").path
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: python)
            proc.arguments = [script, url.path, "--json"]
            proc.environment = WizardViewModel.toolEnvironment()

            let pipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = errPipe

            var decoded: MediaInspection?
            var errText: String?
            do {
                try proc.run()
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
                if proc.terminationStatus == 0 {
                    decoded = try? JSONDecoder().decode(MediaInspection.self, from: data)
                    if decoded == nil {
                        errText = L("vm.inspect.decode_error")
                    }
                } else {
                    errText = WizardViewModel.lastMessage(errBuffer.stored) ?? L("vm.inspect.failed")
                }
            } catch {
                errText = error.localizedDescription
            }

            DispatchQueue.main.async {
                guard generation == self.inspectGeneration else { return }
                self.isInspecting = false
                self.inspection = decoded
                self.inspectionError = errText
            }
        }
    }

    func closeInspector() {
        inspectGeneration += 1
        isInspecting = false
        inspectedTarget = nil
    }

    func resolvePythonPath() -> String {
        AppRuntime.resolvePythonPath(scriptDir: scriptDir)
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
