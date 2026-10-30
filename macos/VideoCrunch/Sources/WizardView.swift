import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct WizardView: View {
    @ObservedObject var vm: WizardViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Main Content by Step
            Group {
                switch vm.currentStep {
                case .scanning:
                    scanView
                case .candidateSelection:
                    selectionView
                case .options:
                    optionsView
                case .encoding:
                    encodingView
                case .completed:
                    completedView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: vm.currentStep)

            // Nothing to act on while scanning or on the empty start screen.
            if vm.currentStep != .scanning {
                Divider()
                bottomBar
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
        // Mac window chrome: what is open as the title, back and the step in
        // the title bar, the way Finder and Gifski place them.
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    goBack()
                } label: {
                    Label("Zurück", systemImage: "chevron.left")
                }
                .help("Zurück (⌘[)")
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!canGoBack)
            }
            ToolbarItem(placement: .principal) {
                stepIndicatorPill
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    vm.chooseAndOpen()
                } label: {
                    Label("Hinzufügen", systemImage: "plus")
                }
                .help("Videos oder Ordner hinzufügen (⌘O)")
            }
        }
        // Drop anywhere, in any step: before a selection it starts, during
        // one it adds, during an encode it waits for the next run.
        .dropDestination(for: URL.self) { urls, _ in
            vm.open(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay {
                        Label(dropHint, systemImage: "plus.circle.fill")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    @State private var dropTargeted = false

    private var dropHint: String {
        switch vm.currentStep {
        case .candidateSelection, .options: return "Zur Auswahl hinzufügen"
        case .encoding: return "Für den nächsten Durchlauf vormerken"
        default: return "Loslassen zum Prüfen"
        }
    }

    private var targetDescription: String? {
        switch vm.targetURLs.count {
        case 0: return nil
        case 1: return vm.targetURLs[0].path
        default:
            let names = vm.targetURLs.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
            return vm.targetURLs.count > 3 ? "\(names) und \(vm.targetURLs.count - 3) weitere" : names
        }
    }

    // MARK: - Subviews

    private var windowTitle: String {
        targetDescription.map { vm.targetURLs.count == 1 ? vm.targetURLs[0].lastPathComponent : $0 }
            ?? "VideoCrunch"
    }

    /// Where the opened item lives, as Finder would abbreviate it.
    private var windowSubtitle: String {
        guard let first = vm.targetURLs.first else { return "" }
        let folder = vm.targetURLs.count == 1 ? first.deletingLastPathComponent() : first
        return (folder.path as NSString).abbreviatingWithTildeInPath
    }

    private var canGoBack: Bool {
        switch vm.currentStep {
        case .options, .candidateSelection: return true
        case .scanning: return vm.errorMessage != nil
        default: return false
        }
    }

    private func goBack() {
        switch vm.currentStep {
        case .options: vm.backToCandidates()
        case .candidateSelection, .scanning: vm.startOver()
        default: break
        }
    }

    private var stepIndicatorPill: some View {
        HStack(spacing: 6) {
            stepDot(title: "Scan", active: vm.currentStep == .scanning)
            stepDot(title: "Auswahl", active: vm.currentStep == .candidateSelection)
            stepDot(title: "Optionen", active: vm.currentStep == .options)
            stepDot(title: "Encode", active: vm.currentStep == .encoding)
            stepDot(title: "Fertig", active: vm.currentStep == .completed)
        }
        .font(.caption2)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(12)
    }

    private func stepDot(title: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(title)
                .foregroundColor(active ? .primary : .secondary)
                .fontWeight(active ? .bold : .regular)
        }
    }

    // MARK: - Step 1: Scan View
    @ViewBuilder
    private var scanView: some View {
        if let err = vm.errorMessage {
            StatusHero(icon: "exclamationmark.triangle.fill", tint: .orange,
                       title: "Scan fehlgeschlagen", message: err) {
                if !vm.targetURLs.isEmpty {
                    Button {
                        vm.startScan(for: vm.targetURLs)
                    } label: {
                        Label("Erneut scannen", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.large)
                }
            }
        } else if vm.targetURLs.isEmpty {
            StatusHero(icon: "film.stack", tint: .accentColor,
                       title: "Videos auswählen",
                       message: "Zieh Videos oder Ordner hierher oder aufs Dock-Symbol – oder wähle sie aus. Es wird erst kodiert, wenn du es bestätigst.") {
                Button {
                    vm.chooseAndOpen()
                } label: {
                    Label("Videos oder Ordner wählen …", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        } else {
            StatusHero(icon: "magnifyingglass", tint: .accentColor,
                       title: "Analysiere Videos …",
                       message: "Liest Auflösung, Codec und Bitrate. Dabei wird nichts kodiert.") {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Step 2: Selection
    @State private var previewURL: URL?
    @State private var hoveredCandidate: String?

    /// Space previews the row under the pointer, as in Finder.
    private func previewHovered() {
        guard let id = hoveredCandidate ?? vm.candidates.first?.id else { return }
        previewURL = previewURL == nil ? URL(fileURLWithPath: id) : nil
    }

    private var selectionView: some View {
        VStack(spacing: 0) {
            Button("Vorschau", action: previewHovered)
                .keyboardShortcut(.space, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text((vm.candidates.count == 1 ? "1 Kandidat" : "\(vm.candidates.count) Kandidaten")
                         + " · \(vm.recommendedIds.count) empfohlen")
                        .font(.headline)
                    Text("Videos, die mindestens 10 % kleiner würden")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if vm.isScanning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Prüfe weitere …")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let notice = vm.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button("Empfohlene") { vm.selectRecommended() }
                    .disabled(vm.selectedIds == vm.recommendedIds)
                    .help("Nur die Videos, bei denen sich das Encodieren voraussichtlich lohnt")
                Button("Alle") { vm.selectAll() }
                    .disabled(vm.selectedIds.count == vm.candidates.count)
                Button("Keine") { vm.deselectAll() }
                    .disabled(vm.selectedIds.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider()

            if vm.candidates.isEmpty {
                StatusHero(icon: "checkmark.seal.fill", tint: .green,
                           title: "Alles optimal",
                           message: "Kein Video würde um mindestens 10 % kleiner. Hier gibt es nichts zu holen.") {
                    EmptyView()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(vm.candidates) { c in
                            CandidateRow(candidate: c, selected: vm.selectedIds.contains(c.id),
                                         toggle: { vm.toggleSelection(for: c.id) },
                                         preview: { previewURL = URL(fileURLWithPath: c.file_path) },
                                         hover: { inside in hoveredCandidate = inside ? c.id : nil })
                        }
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .quickLookPreview($previewURL)
    }

    // MARK: - Step 3: Options View
    private var optionsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                savingsSummary

                previewCard

                if let target = vm.trimTarget, let duration = target.duration_sec {
                    OptionSection(title: "Kürzen") {
                        TrimEditor(url: URL(fileURLWithPath: target.file_path), duration: duration,
                                   start: $vm.trimStart, end: $vm.trimEnd)
                    }
                }

                OptionSection(title: "Codec") {
                    HStack(spacing: 12) {
                        ChoiceCard(
                            icon: "bolt.fill",
                            title: "HEVC / H.265",
                            subtitle: "Hardware-Encoder, schnell. Läuft auf praktisch jedem Gerät.",
                            selected: vm.targetCodec == "hevc"
                        ) { vm.targetCodec = "hevc" }
                        ChoiceCard(
                            icon: "sparkles",
                            title: "AV1",
                            subtitle: "Kleinere Dateien, deutlich langsamer. Braucht neuere Geräte zum Abspielen.",
                            badge: "Experimentell",
                            selected: vm.targetCodec == "av1"
                        ) { vm.targetCodec = "av1" }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    if vm.targetCodec != vm.scannedCodec {
                        Label("Die Ersparnis oben wurde für \(codecName(vm.scannedCodec)) geschätzt.",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                OptionSection(title: "Audio") {
                    HStack(spacing: 12) {
                        ChoiceCard(
                            icon: "speaker.wave.3.fill",
                            title: "Lautheit angleichen",
                            subtitle: "Auf −16 LUFS: leise Handyvideos werden hörbar, laute gezähmt.",
                            selected: vm.audioMode == "enhanced"
                        ) { vm.audioMode = "enhanced" }
                        ChoiceCard(
                            icon: "waveform",
                            title: "Original",
                            subtitle: "Der Ton bleibt, wie er ist. Nur neu kodiert.",
                            selected: vm.audioMode == "standard"
                        ) { vm.audioMode = "standard" }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                OptionSection(title: "Dateien") {
                    VStack(spacing: 0) {
                        if !vm.downscaleOnlyUnselected.isEmpty {
                            // Left unticked because they only pay off downscaled:
                            // offered here, where the downscale is decided.
                            SettingRow(
                                icon: "sparkles",
                                tint: .indigo,
                                title: "\(videoCount(vm.downscaleOnlyUnselected.count)) lohnt sich mit 1080p",
                                subtitle: vm.downscaleOnlyUnselected.prefix(2).map(\.filename)
                                    .joined(separator: ", ")
                                    + " – ohne Verkleinern unter 20 %, darum nicht vorausgewählt."
                            ) {
                                Button("Mitnehmen") {
                                    vm.takeDownscaleOnly()
                                }
                                .help("Auswählen und auf 1080p verkleinern")
                            }
                            Divider().padding(.leading, 54)
                        }
                        if vm.hasTallCandidates {
                            SettingRow(
                                icon: "arrow.down.right.and.arrow.up.left",
                                tint: .blue,
                                title: vm.selectedNeedingDownscale > 0 && !vm.scaleTo1080p
                                    ? "Auf 1080p verkleinern – empfohlen"
                                    : "Auf 1080p verkleinern",
                                subtitle: "\(videoCount(vm.tallCandidatesCount)) über 1080p. Spart zusätzlich ca. \(formatMB(vm.downscaleExtraSavedMB)), Seitenverhältnis bleibt."
                            ) {
                                Toggle("", isOn: $vm.scaleTo1080p)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                            }
                            Divider().padding(.leading, 54)
                        }
                        SettingRow(
                            icon: "trash.fill",
                            tint: vm.moveToTrash && !vm.isTrimmed ? .red : .gray,
                            title: "Originale in den Papierkorb",
                            subtitle: vm.isTrimmed
                                ? "Beim Kürzen bleibt das Original immer erhalten."
                                : vm.moveToTrash
                                ? "Erst nach bestandenem SSIM-Qualitätscheck. Aus dem Papierkorb wiederherstellbar."
                                : "Aus: Das Original bleibt neben der neuen _opt.mp4 liegen."
                        ) {
                            Toggle("", isOn: $vm.moveToTrash)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .disabled(vm.isTrimmed)
                        }
                    }
                    .cardBackground()
                }
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
    }

    /// "So wird es aussehen": a few seconds encoded with these settings,
    /// judged by eye before the full run.
    private var previewCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("So wird es aussehen")
                    .fontWeight(.medium)
                Text(vm.previewError
                     ?? "Kodiert die schwierigste Stelle mit diesen Einstellungen – in Sekunden statt Minuten.")
                    .font(.caption)
                    .foregroundStyle(vm.previewError == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if vm.previewingId != nil {
                ProgressView()
                    .controlSize(.small)
                Text("Erstelle Vorschau …")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if vm.selectedCandidates.count == 1, let only = vm.selectedCandidates.first {
                Button("Vorschau ansehen") {
                    vm.makePreview(for: only) { openWindow(value: $0) }
                }
            } else {
                Menu("Vorschau ansehen") {
                    ForEach(vm.selectedCandidates) { c in
                        Button(c.filename) {
                            vm.makePreview(for: c) { openWindow(value: $0) }
                        }
                    }
                }
                .fixedSize()
            }
        }
        .padding(14)
        .cardBackground()
    }

    /// Before/after at a glance: what the selection weighs now and after.
    private var savingsSummary: some View {
        let before = vm.selectedTotalMB
        let after = vm.selectedTotalAfterMB
        let saved = vm.selectedEstimatedSavedMB
        let fraction = before > 0 ? after / before : 1
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(videoCount(vm.selectedCandidates.count) + " ausgewählt")
                        .font(.headline)
                    Text("\(formatMB(before)) → ca. \(formatMB(after))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let runtime = vm.selectedRuntimeSec {
                        Label("Dauert \(formatDuration(runtime))", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Aus der Dauer früherer Encodes in derselben Auflösung")
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("−\(formatMB(saved))")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.savings)
                        .monospacedDigit()
                    Text(before > 0 ? "ca. \(Int((1 - fraction) * 100)) % kleiner" : "geschätzt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.green.opacity(0.25))
                    Capsule()
                        .fill(Color.accentColor.gradient)
                        .frame(width: max(8, geo.size.width * fraction))
                }
            }
            .frame(height: 8)
            .accessibilityLabel("Danach ca. \(Int(fraction * 100)) % der heutigen Größe")
        }
        .padding(16)
        .cardBackground()
    }

    private func codecName(_ codec: String) -> String {
        codec == "av1" ? "AV1" : "HEVC"
    }

    // MARK: - Step 4: Encoding
    private var encodingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overallProgress

                if !vm.queuedURLs.isEmpty {
                    Label("\(vm.queuedURLs.count == 1 ? "1 weiteres Element" : "\(vm.queuedURLs.count) weitere Elemente") vorgemerkt – danach geht es damit weiter.",
                          systemImage: "tray.and.arrow.down")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                OptionSection(title: "Laufende Encodes") {
                    VStack(spacing: 8) {
                        if vm.workers.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Starte Encoder …")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .cardBackground()
                        } else {
                            ForEach(vm.workers.values.sorted(by: { $0.id < $1.id })) { w in
                                WorkerRow(worker: w)
                            }
                        }
                    }
                }

                DisclosureGroup("Protokoll") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(vm.logs.suffix(40).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                    }
                    .frame(height: 140)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.25))
                    )
                    .padding(.top, 6)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
    }

    /// Whole-batch progress: finished files plus the running files' share.
    private var overallProgress: some View {
        let finished = vm.completedCount + vm.failedCount
        let fraction = vm.overallFraction
        let runningCount = vm.workers.values.filter { $0.status == "running" }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.isEncoding
                         ? "\(finished) von \(vm.totalToEncode) fertig"
                         : "Wird beendet …")
                        .font(.headline)
                    if let start = vm.encodeStartedAt {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            Text((runningCount > 1 ? "\(runningCount) parallel · " : "")
                                 + "läuft seit \(elapsedString(from: start, to: context.date))"
                                 + (vm.remainingSeconds(at: context.date).map { " · noch \(formatDuration($0))" } ?? ""))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                Spacer()
                Text("\(Int(fraction * 100)) %")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            ProgressView(value: fraction)
            HStack(spacing: 8) {
                Chip(text: "\(vm.completedCount) fertig", icon: "checkmark.circle.fill", tint: .savings)
                if vm.failedCount > 0 {
                    Chip(text: "\(vm.failedCount) fehlgeschlagen", icon: "xmark.circle.fill", tint: .red)
                }
            }
        }
        .padding(16)
        .cardBackground()
    }

    private func elapsedString(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Step 5: Completed
    @Environment(\.openWindow) private var openWindow

    /// Source and encode of a finished file, if both are still there to look
    /// at (with "Originale in den Papierkorb" the source is gone).
    private func comparison(for result: BatchItemResult) -> Comparison? {
        guard result.status == "success", let source = result.path,
              let encoded = result.output_path, source != encoded,
              FileManager.default.fileExists(atPath: source),
              FileManager.default.fileExists(atPath: encoded) else { return nil }
        let offset = vm.lastRunTrim.flatMap { $0.path == source ? $0.start : nil } ?? 0
        return Comparison(source: URL(fileURLWithPath: source), encoded: URL(fileURLWithPath: encoded),
                          offset: offset)
    }

    private var completedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                completedHeadline
                    .frame(maxWidth: .infinity)

                if !vm.queuedURLs.isEmpty {
                    queuedCard
                }

                HStack(spacing: 12) {
                    StatTile(title: "Gespart", value: formatBytes(vm.actualSavedBytes), tint: .savings)
                    StatTile(title: "Optimiert", value: "\(vm.completedCount) von \(vm.totalToEncode)", tint: .primary)
                    if vm.wasCancelled {
                        StatTile(title: "Abgebrochen", value: "\(vm.cancelledCount)", tint: .orange)
                    } else {
                        StatTile(title: "Fehlgeschlagen", value: "\(vm.failedCount)",
                                 tint: vm.failedCount > 0 ? .red : .secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                if let floor = vm.suggestedFloor, !vm.retryEligibleCandidates.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "dial.medium.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(videoCount(vm.retryEligibleCandidates.count)) knapp unter der Qualitätsschwelle")
                                .fontWeight(.medium)
                            Text("Mit Schwelle \(String(format: "%.2f", floor)) würden sie angenommen.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Erneut versuchen") {
                            vm.retryFailedWithNewFloor()
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.orange.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.orange.opacity(0.4))
                    )
                }

                if !vm.batchResults.isEmpty {
                    OptionSection(title: "Ergebnisse") {
                        VStack(spacing: 0) {
                            ForEach(Array(vm.batchResults.enumerated()), id: \.offset) { index, r in
                                if index > 0 { Divider().padding(.leading, 46) }
                                ResultRow(result: r, compare: comparison(for: r).map { item in
                                    { openWindow(value: item) }
                                })
                            }
                        }
                        .cardBackground()
                    }
                }
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
    }

    /// What was dropped during the run, ready to be checked next.
    private var queuedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.queuedURLs.count == 1 ? "1 weiteres Element vorgemerkt"
                                              : "\(vm.queuedURLs.count) weitere Elemente vorgemerkt")
                    .fontWeight(.medium)
                Text(vm.queuedURLs.prefix(3).map(\.lastPathComponent).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Jetzt prüfen") {
                vm.scanQueued()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .cardBackground()
    }

    @ViewBuilder
    private var completedHeadline: some View {
        if vm.wasCancelled {
            StatusHero(icon: "stop.circle.fill", tint: .orange, title: "Abgebrochen",
                       message: "\(vm.completedCount) von \(vm.totalToEncode) Videos wurden vor dem Abbruch fertig. Halb fertige Dateien wurden entfernt.",
                       compact: true) { EmptyView() }
        } else if vm.completedCount == 0 {
            StatusHero(icon: "xmark.octagon.fill", tint: .red, title: "Nichts optimiert",
                       message: "Kein Video wurde ersetzt. Die Gründe stehen unten bei den Ergebnissen.",
                       compact: true) { EmptyView() }
        } else {
            StatusHero(icon: "checkmark.circle.fill", tint: .green, title: "Fertig",
                       message: vm.moveToTrash
                           ? "Die Originale liegen im Papierkorb."
                           : "Die neuen Dateien liegen als _opt.mp4 neben den Originalen.",
                       compact: true) { EmptyView() }
        }
    }

    // MARK: - Bottom Action Bar
    /// What the selection will come to — always in view next to the button
    /// that starts it, like Gifski's "Estimated size".
    private var bottomInfo: String? {
        switch vm.currentStep {
        case .candidateSelection:
            return "\(vm.selectedCandidates.count) ausgewählt · ca. −\(formatMB(vm.selectedEstimatedSavedMB))"
        case .options:
            let time = vm.selectedRuntimeSec.map { " · dauert \(formatDuration($0))" } ?? ""
            return "Ergebnis ca. \(formatMB(vm.selectedTotalAfterMB)) · −\(formatMB(vm.selectedEstimatedSavedMB))" + time
        default:
            return nil
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if vm.currentStep == .encoding {
                Button(role: .destructive) {
                    vm.cancelEncoding()
                } label: {
                    Label("Abbrechen", systemImage: "stop.fill")
                }
                .controlSize(.large)
                .disabled(!vm.isEncoding)
            } else if vm.currentStep == .completed, !vm.targetURLs.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(vm.targetURLs)
                } label: {
                    Label("Im Finder zeigen", systemImage: "folder")
                }
                .controlSize(.large)
            }

            if let info = bottomInfo {
                Text(info)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer()

            if vm.currentStep == .candidateSelection {
                let count = vm.selectedCandidates.count
                Button {
                    vm.proceedToOptions()
                } label: {
                    Label("Weiter", systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
            } else if vm.currentStep == .options {
                Button {
                    vm.startEncoding()
                } label: {
                    Label("Encode starten", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else if vm.currentStep == .completed {
                // Back to the start rather than quitting: the app lives in
                // the Dock now, and ⌘Q is there for leaving.
                Button {
                    vm.startOver()
                } label: {
                    Label("Neue Videos …", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

func videoCount(_ n: Int) -> String {
    n == 1 ? "1 Video" : "\(n) Videos"
}

// MARK: - Option building blocks

/// Grouped card surface, the way System Settings draws its sections.
private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
    }
}

extension View {
    func cardBackground() -> some View {
        modifier(CardBackground())
    }
}

/// A titled group of options.
private struct OptionSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            content
        }
    }
}

/// One of several mutually exclusive choices, shown as a selectable card.
private struct ChoiceCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var badge: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                HStack(spacing: 6) {
                    Text(title)
                        .fontWeight(.semibold)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                            .foregroundStyle(.orange)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected
                          ? Color.accentColor.opacity(0.12)
                          : Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Icon tile, title and explanation on the left, a control on the right.
private struct SettingRow<Trailing: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// macOS Visual Effect View for native blur
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Shared building blocks

/// Big round icon, title and explanation — for waiting, empty, error and done states.
private struct StatusHero<Accessory: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String?
    var compact: Bool = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: compact ? 60 : 76, height: compact ? 60 : 76)
                Image(systemName: icon)
                    .font(.system(size: compact ? 26 : 32, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.title2.weight(.semibold))
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .textSelection(.enabled)
            }
            accessory
                .padding(.top, 4)
        }
        .padding(compact ? 8 : 32)
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
    }
}

/// Small rounded label for codec, resolution, counts.
private struct Chip: View {
    let text: String
    var icon: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
            }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.15)))
        .foregroundStyle(tint == .secondary ? Color.primary.opacity(0.75) : tint)
    }
}

/// Share of a file the encode is expected to save.
private struct SavingsBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(Color.green.gradient)
                    .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
            }
        }
    }
}

/// One scan candidate; the whole card toggles its selection.
private struct CandidateRow: View {
    let candidate: Candidate
    let selected: Bool
    let toggle: () -> Void
    let preview: () -> Void
    let hover: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])

            Button(action: preview) {
                Image(systemName: "eye")
                    .font(.body)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.6))
            .help("Vorschau (Leertaste)")
            .accessibilityLabel("Vorschau von \(candidate.filename)")
            .padding(.trailing, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected
                      ? Color.accentColor.opacity(0.08)
                      : Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
        )
        .onHover { inside in
            hovering = inside
            hover(inside)
        }
    }

    private var content: some View {
            HStack(spacing: 14) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                VideoThumbnail(url: URL(fileURLWithPath: candidate.file_path))
                VStack(alignment: .leading, spacing: 5) {
                    Text(candidate.filename)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Chip(text: candidate.codec.uppercased())
                        Chip(text: candidate.resolutionString)
                        Chip(text: String(format: "%.1f Mbit/s", candidate.bitrate_mbps))
                        if candidate.source == "history" {
                            Chip(text: "aus Verlauf", icon: "clock.arrow.circlepath", tint: .blue)
                        }
                    }
                    if let advice = candidate.advice, !candidate.isRecommended {
                        Label(advice, systemImage: candidate.recommended_1080 == true
                              ? "arrow.down.right.and.arrow.up.left" : "lightbulb")
                            .font(.caption)
                            .foregroundStyle(candidate.recommended_1080 == true ? Color.blue : Color.secondary)
                            .lineLimit(1)
                    } else {
                        Text(candidate.reasonDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 5) {
                    Text("−\(candidate.savedFormatted)")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(Color.savings)
                        .monospacedDigit()
                    SavingsBar(fraction: candidate.estimated_saved_pct / 100)
                        .frame(width: 90, height: 5)
                    Text("\(Int(candidate.estimated_saved_pct.rounded())) % von \(candidate.sizeFormatted)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let pct1080 = candidate.estimated_saved_pct_1080 {
                        Text("mit 1080p: \(Int(pct1080.rounded())) %")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.blue)
                            .monospacedDigit()
                    }
                }
            }
            .padding(12)
            .contentShape(Rectangle())
    }
}

/// One parallel encode slot.
private struct WorkerRow: View {
    let worker: WorkerStatus

    private var look: (icon: String, tint: Color, label: String) {
        switch worker.status {
        case "done": return ("checkmark.circle.fill", .green, "Fertig")
        case "failed": return ("xmark.circle.fill", .red, "Fehlgeschlagen")
        case "skipped": return ("forward.circle.fill", .secondary, "Übersprungen")
        case "cancelled": return ("stop.circle.fill", .orange, "Abgebrochen")
        default: return ("film", .accentColor, "\(Int(worker.fileFraction * 100)) %")
        }
    }

    /// What the running encode is doing right now.
    private var step: String? {
        guard worker.status == "running" else { return nil }
        switch worker.phase {
        case "encode": return "Durchgang \(worker.pass) · encodiert \(worker.progress) %"
        case "check": return "Durchgang \(worker.pass) · prüft Qualität"
        default: return "Analysiert …"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: look.icon)
                    .foregroundStyle(look.tint)
                Text(worker.file.isEmpty ? "Encoder \(worker.id) startet …" : worker.file)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if worker.status == "running" && worker.q > 0 {
                    Chip(text: "Q \(worker.q)")
                        .help("Qualitätsstufe, die gerade ausprobiert wird")
                }
                Text(look.label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(worker.status == "running" ? Color.primary : look.tint)
                    .monospacedDigit()
            }
            ProgressView(value: worker.fileFraction)
                .tint(look.tint)
            if let step {
                Text(step)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(12)
        .cardBackground()
    }
}

/// A labelled number in the summary row.
private struct StatTile: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
        .cardBackground()
    }
}

/// One file's outcome from batch.py's report.
private struct ResultRow: View {
    let result: BatchItemResult
    /// Opens the before/after comparison; nil when there is nothing to compare.
    var compare: (() -> Void)? = nil

    private var look: (icon: String, tint: Color) {
        switch result.status {
        case "success": return ("checkmark.circle.fill", .green)
        case "skipped": return ("forward.circle.fill", .secondary)
        case "cancelled": return ("stop.circle.fill", .orange)
        default: return ("xmark.circle.fill", .red)
        }
    }

    private var detail: String {
        if result.status == "success" {
            var parts: [String] = []
            if let pct = result.saved_pct { parts.append("−\(Int(pct.rounded())) %") }
            if let ssim = result.ssim { parts.append(String(format: "SSIM %.3f", ssim)) }
            if let q = result.quality { parts.append("Q \(q)") }
            return parts.joined(separator: " · ")
        }
        switch result.status {
        case "cancelled": return "Abgebrochen, bevor es fertig war"
        case "skipped": return result.reason ?? "Übersprungen"
        default: return result.reason ?? "Fehlgeschlagen"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: look.icon)
                .font(.title3)
                .foregroundStyle(look.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.filename ?? "Unbekannte Datei")
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if result.status == "success" {
                    losses
                }
            }
            Spacer(minLength: 12)
            if let compare {
                Button(action: compare) {
                    Label("Vergleichen", systemImage: "rectangle.split.2x1")
                }
                .controlSize(.small)
                .help("Original und Ergebnis nebeneinander ansehen")
            }
            if result.status == "success", let bytes = result.saved_bytes {
                Text("−\(formatBytes(bytes))")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.savings)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// What the encode could not keep: said here, not left to be discovered.
    @ViewBuilder
    private var losses: some View {
        if let dv = result.dolby_vision, let kept = dv.kept_as {
            Label("Dolby Vision \(dv.profile) → \(kept)-HDR (ohne dynamische Metadaten)",
                  systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
        if let dropped = result.dropped, !dropped.isEmpty {
            Label("Nicht alle Spuren übernommen", systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help(dropped.joined(separator: "\n"))
        }
    }
}
