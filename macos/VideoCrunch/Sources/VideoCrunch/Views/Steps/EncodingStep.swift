import AppKit
import SwiftUI

/// Step 4: studio telemetry & live encoding progress.
struct EncodingStep: View {
    @ObservedObject var vm: WizardViewModel
    @StateObject private var systemLoad = SystemLoadMonitor()
    @State private var selectedWorkerId: Int?
    @State private var showLog = false
    @State private var copiedLog = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !vm.queuedURLs.isEmpty {
                    Label(vm.queuedURLs.count == 1
                          ? L("encoding.queued_one")
                          : L("encoding.queued_many_fmt", vm.queuedURLs.count),
                          systemImage: "tray.and.arrow.down")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardBackground()
                }

                if vm.totalToEncode > 1 {
                    batchMasterDetailLayout
                } else {
                    singleFocusLayout
                }
            }
            .frame(maxWidth: 1080)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if vm.isEncoding {
                systemLoad.start()
            }
        }
        .onChange(of: vm.isEncoding) { _, active in
            if active {
                systemLoad.start()
            } else {
                systemLoad.stop()
            }
        }
        .onDisappear {
            systemLoad.stop()
        }
    }

    // MARK: - Single-Video Studio Layout

    private var singleFocusLayout: some View {
        let worker = singleWorker
        return HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                stagePreviewCard(worker: worker, height: nil)
                jobBriefCard(worker: worker)
            }
            .frame(width: 340)

            VStack(alignment: .leading, spacing: 14) {
                heroProgressCard(worker: worker, showFilename: false)
                telemetryStrip(worker: worker)
                pipelineCard(worker: worker)
                protocolDisclosure
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: shouldShowTelemetry(for: worker))
        }
    }

    private var singleWorker: WorkerStatus? {
        let sorted = vm.workers.values.sorted(by: { $0.id < $1.id })
        return sorted.first(where: { $0.status == "running" }) ?? sorted.first
    }

    // MARK: - Batch Master-Detail Layout

    private var batchMasterDetailLayout: some View {
        let sortedWorkers = vm.workers.values.sorted(by: { $0.id < $1.id })
        let focused = selectedBatchWorker(from: sortedWorkers)
        return VStack(alignment: .leading, spacing: 18) {
            batchMasterBanner(runningCount: sortedWorkers.filter { $0.status == "running" }.count)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    OptionSection(title: L("encoding.active_encoders")) {
                        VStack(spacing: 8) {
                            if sortedWorkers.isEmpty {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text(L("encoding.starting"))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(16)
                                .cardBackground()
                            } else {
                                ForEach(sortedWorkers) { w in
                                    CompactWorkerRow(worker: w, selected: focused?.id == w.id) {
                                        selectedWorkerId = w.id
                                    }
                                }
                            }
                        }
                    }

                    if !vm.completedFiles.isEmpty {
                        OptionSection(title: L("encoding.already_done")) {
                            VStack(spacing: 6) {
                                ForEach(Array(vm.completedFiles.suffix(20).reversed())) { item in
                                    completedMiniRow(item)
                                }
                            }
                        }
                    }
                }
                .frame(width: 340)

                VStack(alignment: .leading, spacing: 14) {
                    if let focused {
                        stagePreviewCard(worker: focused, height: 156)
                        heroProgressCard(worker: focused, showFilename: true)
                        telemetryStrip(worker: focused)
                        pipelineCard(worker: focused)
                    } else {
                        heroProgressCard(worker: nil, showFilename: true)
                    }
                    protocolDisclosure
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: shouldShowTelemetry(for: focused))
            }
        }
    }

    private func selectedBatchWorker(from sorted: [WorkerStatus]) -> WorkerStatus? {
        if let selectedWorkerId, let match = sorted.first(where: { $0.id == selectedWorkerId }) {
            return match
        }
        return sorted.first(where: { $0.status == "running" }) ?? sorted.first
    }

    private func batchMasterBanner(runningCount: Int) -> some View {
        let finished = vm.completedCount + vm.failedCount
        let fraction = vm.overallFraction
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.isEncoding
                         ? L("encoding.done_of_fmt", finished, vm.totalToEncode)
                         : L("encoding.finishing"))
                        .font(.headline)
                    if let start = vm.encodeStartedAt {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            let parallel = runningCount > 1 ? L("encoding.parallel_fmt", runningCount) : ""
                            let elapsed = L("encoding.elapsed_fmt", elapsedString(from: start, to: context.date))
                            let eta = vm.remainingSeconds(at: context.date).map { L("encoding.eta_fmt", formatDuration($0)) } ?? ""
                            Text(parallel + elapsed + eta)
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
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: Int(fraction * 100))
            }

            CrunchProgressBar(
                fraction: fraction,
                active: vm.isEncoding,
                indeterminate: vm.isEncoding && fraction == 0 && vm.workers.values.allSatisfy { $0.phase == "prepare" && $0.progress == 0 },
                height: 7
            )

            HStack(spacing: 8) {
                Chip(text: L("encoding.done_count_fmt", vm.completedCount),
                     icon: "checkmark.circle.fill", tint: .savings, monospaced: true)
                if vm.failedCount > 0 {
                    Chip(text: L("encoding.failed_count_fmt", vm.failedCount),
                         icon: "xmark.circle.fill", tint: .red, monospaced: true)
                }
                if vm.liveSavedBytes > 0 {
                    Chip(text: L("encoding.saved_so_far_fmt", formatBytes(vm.liveSavedBytes)),
                         icon: "arrow.down.circle.fill",
                         tint: .savings,
                         monospaced: true)
                }
            }
        }
        .padding(16)
        .cardBackground()
    }

    private func completedMiniRow(_ item: CompletedWorkerItem) -> some View {
        let tint: Color = item.status == "success" ? .savings : (item.status == "skipped" ? .secondary : .red)
        let icon: String = item.status == "success" ? "checkmark.circle.fill" : (item.status == "skipped" ? "forward.circle.fill" : "xmark.circle.fill")
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
            Text(item.file)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if item.status == "success", let saved = item.savedPct, saved > 0.5 {
                Text(L("detail.encode_saved_fmt", Int(saved.rounded())))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.savings)
                    .monospacedDigit()
            } else if item.status == "skipped" {
                Text(L("encoding.skipped"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .cardBackground()
    }

    // MARK: - Left Column Building Blocks

    @ViewBuilder
    private func stagePreviewCard(worker: WorkerStatus?, height: CGFloat?) -> some View {
        let path = (worker?.path.isEmpty == false ? worker?.path : nil)
            ?? vm.selectedCandidates.first?.file_path
            ?? vm.targetURLs.first?.path
        let candidate = path.flatMap { vm.candidate(forPath: $0) }
        let title: String = {
            if vm.lastRunWasMerge || vm.isMerge {
                let count = vm.lastRunMergeClipCount > 0 ? vm.lastRunMergeClipCount : vm.orderedMergeCandidates.count
                return L("options.merge.title_fmt", videoCount(count))
            }
            if let name = worker?.file, !name.isEmpty { return name }
            if let name = candidate?.filename { return name }
            return path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L("menu.video")
        }()
        let duration: Double? = {
            if vm.lastRunWasMerge || vm.isMerge {
                let total = vm.orderedMergeCandidates.compactMap(\.duration_sec).reduce(0, +)
                return total > 0 ? total : nil
            }
            return candidate?.duration_sec
        }()
        let trimRange: (start: Double, end: Double)? = {
            if (vm.isTrimmed || vm.isGif), let range = vm.gifRange ?? (vm.isTrimmed ? (vm.trimStart, vm.trimEnd) : nil) {
                return range
            }
            return nil
        }()
        let badge: String? = {
            if vm.isGif { return "GIF" }
            if vm.lastRunWasMerge || vm.isMerge { return L("completed.merge_badge") }
            if vm.lastRunWasTrimOnly || vm.isTrimOnly { return L("completed.stream_copy") }
            if let candidate {
                return "\(candidate.codec.uppercased()) · \(candidate.resolutionString)"
            }
            return nil
        }()

        if let path {
            VideoStagePreview(
                url: URL(fileURLWithPath: path),
                title: title,
                duration: duration,
                trimRange: trimRange,
                badge: badge,
                height: height
            )
        }
    }

    private func jobBriefCard(worker: WorkerStatus?) -> some View {
        let candidate = worker.flatMap { vm.candidate(forPath: $0.path) } ?? vm.selectedCandidates.first
        let sourceText: String? = {
            if vm.lastRunWasMerge || vm.isMerge {
                let count = vm.lastRunMergeClipCount > 0 ? vm.lastRunMergeClipCount : vm.orderedMergeCandidates.count
                return L("encoding.brief.merge_clips_fmt", count, formatMB(vm.selectedTotalMB))
            }
            guard let c = candidate else { return nil }
            let dims = c.dimensionsString ?? c.resolutionString
            return "\(dims) · \(c.codec.uppercased()) · \(c.sizeFormatted)"
        }()

        return VStack(alignment: .leading, spacing: 10) {
            Text(L("encoding.brief.title"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 7) {
                if let sourceText {
                    briefRow(label: L("encoding.brief.source"), value: sourceText)
                }
                briefRow(label: L("encoding.brief.goal"), value: vm.activeTargetSummary)
                if let audio = vm.activeAudioSummary {
                    briefRow(label: L("encoding.brief.audio"), value: audio)
                }
                if vm.isTrimmed || vm.isGif, let range = vm.gifRange ?? (vm.isTrimmed ? (vm.trimStart, vm.trimEnd) : nil) {
                    let span = max(0, range.end - range.start)
                    briefRow(label: L("encoding.brief.clip"), value: "\(clock(range.start)) – \(clock(range.end)) (\(formatDuration(span)))")
                }
            }

            if vm.isGif, let est = vm.gifEstimate {
                Divider().opacity(0.6)
                HStack {
                    Text(L("encoding.brief.expected"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(L("encoding.brief.approx_fmt", formatBytes(est.estimated_bytes))) · \(est.width)×\(est.height)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            } else if vm.selectedTotalMB > 0 && !(vm.lastRunWasMerge || vm.isMerge) {
                Divider().opacity(0.6)
                let before = vm.selectedTotalMB
                let after = vm.selectedTotalAfterMB
                let saved = vm.selectedEstimatedSavedMB
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L("encoding.brief.expected"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(L("encoding.brief.approx_fmt", formatMB(after)))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                        if saved > 0.1 {
                            Text("−\(formatMB(saved))")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.savings)
                                .monospacedDigit()
                        }
                    }
                    CrunchMeterBar(fraction: min(1, max(0, after / before)))
                }
            }
        }
        .padding(14)
        .cardBackground()
    }

    private func briefRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
    }

    // MARK: - Right Column Cockpit

    private func heroProgressCard(worker: WorkerStatus?, showFilename: Bool) -> some View {
        let isPreparing = vm.isEncoding && (worker == nil || (worker?.phase == "prepare" && (worker?.pass ?? 0) == 0))
        let fraction = worker?.fileFraction ?? vm.overallFraction
        let pct = Int((fraction * 100).rounded())

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if showFilename, let worker, !worker.file.isEmpty {
                        Text(worker.file)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(phaseHeadline(for: worker))
                        .font(.headline)

                    if let start = vm.encodeStartedAt {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            let elapsed = L("encoding.elapsed_fmt", elapsedString(from: start, to: context.date))
                            let eta = vm.totalToEncode == 1
                                ? vm.remainingSeconds(at: context.date).map { L("encoding.eta_fmt", formatDuration($0)) } ?? ""
                                : ""
                            Text(elapsed + eta)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                Spacer(minLength: 8)

                if isPreparing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L("encoding.analysis"))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.brandTeal)
                    }
                } else {
                    Text("\(pct) %")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: pct)
                }
            }

            CrunchProgressBar(
                fraction: fraction,
                active: vm.isEncoding && (worker == nil || worker?.status == "running"),
                indeterminate: isPreparing,
                tint: statusTint(for: worker),
                height: 8
            )

            if let detail = worker?.detail, !detail.isEmpty {
                Label(detail, systemImage: "waveform.path.ecg")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if vm.isEncoding {
                Divider().opacity(0.45)
                hardwareLoadBar(worker: worker)
            }
        }
        .padding(16)
        .cardBackground()
    }

    private func hardwareLoadBar(worker: WorkerStatus?) -> some View {
        let badge = activeHardwareBadge(worker: worker)
        return HStack(spacing: 12) {
            Chip(
                text: badge.label,
                icon: badge.icon,
                tint: badge.accent ? .brandTeal : .secondary
            )

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                loadGauge(label: "CPU", percent: systemLoad.cpuPercent)
                if let gpu = systemLoad.gpuPercent {
                    loadGauge(label: "GPU", percent: gpu)
                }
            }
        }
    }

    private func activeHardwareBadge(worker: WorkerStatus?) -> (label: String, icon: String, accent: Bool) {
        if vm.lastRunWasMerge || vm.isMerge || vm.lastRunWasTrimOnly || vm.isTrimOnly || worker?.detailCode == "copy_mode" {
            return (L("completed.stream_copy"), "scissors", false)
        }
        if vm.isGif {
            if (systemLoad.gpuPercent ?? 0) >= 15 {
                return (L("encoding.telemetry.hardware_cpu_gpu"), "cpu", true)
            }
            return (L("encoding.telemetry.hardware_cpu"), "cpu", false)
        }
        if worker?.phase == "check" {
            return (L("encoding.telemetry.hardware_cpu_ssim"), "eye", true)
        }
        if worker?.phase == "encode" {
            if vm.targetCodec == "av1" {
                return (L("encoding.telemetry.hardware_cpu_av1"), "cpu", true)
            }
            return (L("encoding.telemetry.hardware_media_engine"), "bolt.horizontal.circle.fill", true)
        }
        return (L("encoding.telemetry.hardware_cpu"), "cpu", false)
    }

    private func loadGauge(label: String, percent: Int?) -> some View {
        let clamped = percent.map { max(0, min(100, $0)) }
        let tint: Color = {
            guard let clamped else { return .secondary }
            if clamped > 90 { return .red }
            if clamped >= 70 { return .orange }
            return .brandTeal
        }()
        let barFraction = CGFloat(clamped ?? 0) / 100.0
        let valueText = clamped.map { "\($0) %" } ?? L("encoding.telemetry.measuring")

        return HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                    if clamped != nil {
                        Capsule()
                            .fill(tint)
                            .frame(width: max(3, geo.size.width * barFraction))
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: clamped)
                    }
                }
            }
            .frame(width: 44, height: 5)

            Text(valueText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(clamped == nil ? .secondary : .primary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 32, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(valueText)")
    }

    private func shouldShowTelemetry(for worker: WorkerStatus?) -> Bool {
        if vm.lastRunWasMerge || vm.isMerge || vm.lastRunWasTrimOnly || vm.isTrimOnly {
            return false
        }
        if vm.isGif {
            return true
        }
        guard let worker else { return false }
        return worker.pass > 0 || worker.phase == "encode" || worker.phase == "check"
    }

    @ViewBuilder
    private func telemetryStrip(worker: WorkerStatus?) -> some View {
        let show = shouldShowTelemetry(for: worker)
        if show {
            Group {
                if vm.isGif {
                    HStack(spacing: 10) {
                        telemetryTile(
                            title: L("encoding.telemetry.fps"),
                            value: "\(vm.gifFPS) fps",
                            tint: Color.brandTeal
                        )
                        telemetryTile(
                            title: L("encoding.telemetry.width"),
                            value: "\(vm.gifWidth) px",
                            tint: Color.primary
                        )
                        telemetryTile(
                            title: L("encoding.telemetry.encoder"),
                            value: vm.gifEstimate?.encoder ?? "FFmpeg",
                            tint: Color.primary
                        )
                    }
                } else {
                    let isCheck = worker?.phase == "check"
                    let rawSpeed = isCheck ? worker?.lastPassSpeed : (worker?.speed ?? worker?.lastPassSpeed)
                    let rawBitrate = isCheck ? worker?.lastPassBitrate : (worker?.bitrate ?? worker?.lastPassBitrate)
                    let speedText = formatLiveSpeed(rawSpeed)
                    let bitrateText = formatLiveBitrate(rawBitrate)
                    let third = thirdTelemetryTile(worker: worker)

                    HStack(spacing: 10) {
                        telemetryTile(
                            title: L("encoding.telemetry.speed"),
                            value: speedText ?? L("encoding.telemetry.measuring"),
                            tint: (!isCheck && speedText != nil) ? Color.brandTeal : Color.secondary
                        )
                        telemetryTile(
                            title: L("encoding.telemetry.bitrate"),
                            value: bitrateText ?? L("encoding.telemetry.measuring"),
                            tint: (!isCheck && bitrateText != nil) ? Color.primary : Color.secondary
                        )
                        telemetryTile(
                            title: third.title,
                            value: third.value,
                            tint: third.active ? Color.primary : Color.secondary
                        )
                    }
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func telemetryTile(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .cardBackground()
    }

    private func thirdTelemetryTile(worker: WorkerStatus?) -> (title: String, value: String, active: Bool) {
        if vm.lastRunSizeLimitMB > 0 {
            let p = worker?.pass ?? 0
            return (L("encoding.telemetry.attempt"), p > 0 ? L("encoding.telemetry.attempt_fmt", p) : L("encoding.telemetry.planning"), p > 0)
        }
        let q = worker?.q ?? 0
        return (L("encoding.telemetry.quality_level"), q > 0 ? L("detail.encode_q_fmt", q) : L("encoding.telemetry.measuring"), q > 0)
    }

    // MARK: - Live Pipeline & Pass History

    private func pipelineCard(worker: WorkerStatus?) -> some View {
        let title: String = {
            if vm.lastRunSizeLimitMB > 0 { return L("encoding.pipeline.size_limit") }
            if vm.isGif || vm.lastRunWasTrimOnly || vm.lastRunWasMerge { return L("encoding.pipeline.default") }
            return L("encoding.pipeline.quality")
        }()

        return VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if vm.isGif {
                gifPipelineRows(worker: worker)
            } else if vm.lastRunWasMerge || vm.isMerge {
                mergePipelineRows(worker: worker)
            } else if vm.lastRunWasTrimOnly || vm.isTrimOnly {
                trimPipelineRows(worker: worker)
            } else if vm.lastRunSizeLimitMB > 0 {
                sizeLimitPipelineRows(worker: worker)
            } else {
                qualitySearchPipelineRows(worker: worker)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    @ViewBuilder
    private func qualitySearchPipelineRows(worker: WorkerStatus?) -> some View {
        let hasStartedPasses = (worker?.pass ?? 0) > 0 || !(worker?.passHistory.isEmpty ?? true) || worker?.status == "done"
        let notesText: String = {
            if let notes = worker?.analysisNotes, !notes.isEmpty {
                return notes.joined(separator: " · ")
            }
            return hasStartedPasses ? L("encoding.completed_short") : L("encoding.analysis_sub")
        }()

        VStack(alignment: .leading, spacing: 9) {
            pipelineStepRow(
                state: hasStartedPasses ? .done : (vm.isEncoding ? .active : .pending),
                title: L("encoding.analysis"),
                subtitle: notesText
            )

            if let worker {
                ForEach(worker.passHistory) { attempt in
                    passAttemptRow(attempt)
                }

                let activePassRecorded = worker.pass > 0 && worker.passHistory.contains(where: { $0.pass == worker.pass })
                if worker.status == "running" && worker.pass > 0 && !activePassRecorded {
                    let passTitle = worker.q > 0
                        ? L("encoding.pass_q_fmt", worker.pass, worker.q)
                        : L("encoding.pass_fmt", worker.pass)
                    let phaseLabel = worker.phase == "check"
                        ? L("encoding.check_pct_fmt", worker.progress)
                        : L("encoding.encode_pct_fmt", worker.progress)
                    pipelineStepRow(
                        state: .active,
                        title: passTitle,
                        subtitle: phaseLabel
                    )
                }
            }

            if !hasStartedPasses {
                pipelineStepRow(
                    state: .pending,
                    title: L("encoding.passes_pending_title"),
                    subtitle: L("encoding.passes_pending_sub")
                )
            }

            let isFinalizing = worker?.detailCode == "finalizing"
                || worker?.detailCode == "integrity_verified"
                || worker?.detail?.contains("Faststart") == true
                || worker?.detail?.contains("Integrität") == true
            if isFinalizing {
                pipelineStepRow(
                    state: (worker?.detailCode == "integrity_verified" || worker?.detail?.contains("Integrität") == true) ? .done : .active,
                    title: L("encoding.finalizing"),
                    subtitle: worker?.detail ?? L("encoding.finalizing_sub")
                )
            }
        }
    }

    @ViewBuilder
    private func sizeLimitPipelineRows(worker: WorkerStatus?) -> some View {
        let startedAttempts = (worker?.pass ?? 0) > 0 || !(worker?.passHistory.isEmpty ?? true) || worker?.status == "done"
        VStack(alignment: .leading, spacing: 9) {
            pipelineStepRow(
                state: startedAttempts ? .done : .active,
                title: L("encoding.sizelimit.plan_title"),
                subtitle: L("encoding.sizelimit.plan_sub_fmt", vm.lastRunSizeLimitMB)
            )

            if let worker {
                ForEach(worker.passHistory) { attempt in
                    let isGood = attempt.verdict == "accepted"
                    pipelineStepRow(
                        state: isGood ? .done : .adjusted,
                        title: L("encoding.attempt_fmt", attempt.pass),
                        subtitle: attempt.note ?? (isGood ? L("encoding.attempt_fits") : L("encoding.attempt_too_big")),
                        trailingBadge: isGood ? L("encoding.badge_fits") : L("encoding.badge_adjust"),
                        trailingTint: isGood ? .savings : .orange
                    )
                }

                let currentRecorded = worker.pass > 0 && worker.passHistory.contains(where: { $0.pass == worker.pass })
                if worker.status == "running" && worker.pass > 0 && !currentRecorded {
                    pipelineStepRow(
                        state: .active,
                        title: L("encoding.attempt_fmt", worker.pass),
                        subtitle: worker.detail ?? L("encoding.encode_pct_fmt", worker.progress)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func trimPipelineRows(worker: WorkerStatus?) -> some View {
        let isDone = worker?.status == "done"
        let isEncodingPass = (worker?.phase == "encode" || (worker?.progress ?? 0) > 0) || isDone
        VStack(alignment: .leading, spacing: 9) {
            pipelineStepRow(
                state: isEncodingPass ? .done : .active,
                title: L("encoding.trim.step1"),
                subtitle: L("encoding.trim.step1_sub")
            )
            pipelineStepRow(
                state: isDone ? .done : (isEncodingPass ? .active : .pending),
                title: L("encoding.trim.step2"),
                subtitle: worker?.detail ?? L("encoding.trim.step2_sub")
            )
        }
    }

    @ViewBuilder
    private func mergePipelineRows(worker: WorkerStatus?) -> some View {
        let isDone = worker?.status == "done"
        let isCopying = (worker?.progress ?? 0) > 0 || worker?.phase == "encode" || isDone
        let clipCount = vm.lastRunMergeClipCount > 0 ? vm.lastRunMergeClipCount : vm.orderedMergeCandidates.count
        VStack(alignment: .leading, spacing: 9) {
            pipelineStepRow(
                state: isCopying ? .done : .active,
                title: L("encoding.merge.step1"),
                subtitle: L("encoding.merge.step1_sub_fmt", clipCount)
            )
            pipelineStepRow(
                state: isDone ? .done : (isCopying ? .active : .pending),
                title: L("encoding.merge.step2"),
                subtitle: worker?.detail ?? L("encoding.merge.step2_sub")
            )
        }
    }

    @ViewBuilder
    private func gifPipelineRows(worker: WorkerStatus?) -> some View {
        let isDone = worker?.status == "done"
        let runningGif = worker?.phase == "gif" || (worker?.progress ?? 0) > 0
        VStack(alignment: .leading, spacing: 9) {
            pipelineStepRow(
                state: runningGif || isDone ? .done : .active,
                title: L("encoding.gif.step1"),
                subtitle: L("encoding.gif.step1_sub_fmt", vm.gifFPS, vm.gifWidth)
            )
            pipelineStepRow(
                state: isDone ? .done : (runningGif ? .active : .pending),
                title: L("encoding.gif.step2"),
                subtitle: runningGif ? L("encoding.gif.rendered_pct_fmt", worker?.progress ?? 0) : L("encoding.gif.waiting")
            )
        }
    }

    private enum PipelineStepState {
        case done, active, adjusted, pending
    }

    private func pipelineStepRow(
        state: PipelineStepState,
        title: String,
        subtitle: String?,
        trailingBadge: String? = nil,
        trailingTint: Color = .secondary
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            stepGlyph(state)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(state == .active ? .semibold : .medium))
                    .foregroundStyle(state == .pending ? Color.secondary : Color.primary)
                    .monospacedDigit()
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .monospacedDigit()
                }
            }

            Spacer(minLength: 8)

            if let trailingBadge {
                Chip(text: trailingBadge, tint: trailingTint, monospaced: true)
            }
        }
    }

    private func passAttemptRow(_ attempt: PassAttempt) -> some View {
        let isGood = attempt.verdict == "early_exit" || attempt.verdict == "evaluated" || attempt.verdict == "accepted"
        let state: PipelineStepState = isGood ? .done : .adjusted
        let rowTitle = attempt.q.map { L("encoding.pass_q_fmt", attempt.pass, $0) } ?? L("encoding.pass_fmt", attempt.pass)

        return HStack(alignment: .top, spacing: 10) {
            stepGlyph(state)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .monospacedDigit()
                Text(verdictLabel(for: attempt.verdict))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                if let saved = attempt.savedPct {
                    Chip(
                        text: L("detail.encode_saved_fmt", Int(saved.rounded())),
                        tint: saved >= 10 ? .savings : .secondary,
                        monospaced: true
                    )
                }
                if let ssim = attempt.ssim {
                    let metric = attempt.metric ?? "SSIM"
                    let metricTint: Color = (attempt.verdict == "too_low" || attempt.verdict == "quality_short")
                        ? .orange
                        : .brandTeal
                    Chip(
                        text: "\(metric) \(String(format: "%.3f", ssim))",
                        tint: metricTint,
                        monospaced: true
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func stepGlyph(_ state: PipelineStepState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.savings)
                .frame(width: 14, height: 14)
        case .active:
            Circle()
                .fill(Color.brandTeal)
                .frame(width: 8, height: 8)
                .frame(width: 14, height: 14)
        case .adjusted:
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(width: 14, height: 14)
        case .pending:
            Circle()
                .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1.5)
                .frame(width: 10, height: 10)
                .frame(width: 14, height: 14)
        }
    }

    // MARK: - Protocol Disclosure

    private var protocolDisclosure: some View {
        DisclosureGroup(isExpanded: $showLog) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("encoding.log.lines_fmt", vm.logs.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(vm.logs.joined(separator: "\n"), forType: .string)
                        copiedLog = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copiedLog = false
                        }
                    } label: {
                        Label(copiedLog ? L("action.copied") : L("encoding.log.copy"),
                              systemImage: copiedLog ? "checkmark" : "doc.on.doc")
                    }
                    .controlSize(.small)
                    .disabled(vm.logs.isEmpty)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(vm.logs.suffix(200).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .textSelection(.enabled)
                }
                .frame(height: 150)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.25))
                )
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text(L("encoding.log"))
                if !vm.logs.isEmpty {
                    Text("(\(vm.logs.count))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    // MARK: - Formatting Helpers

    private func phaseHeadline(for worker: WorkerStatus?) -> String {
        if !vm.isEncoding {
            return vm.wasCancelled ? L("encoding.cancelling") : L("encoding.finishing")
        }
        guard let worker else { return L("encoding.starting") }
        switch worker.status {
        case "done": return L("action.done")
        case "failed": return L("encoding.failed")
        case "skipped": return L("encoding.skipped")
        case "cancelled": return L("encoding.cancelled")
        default: break
        }
        if vm.lastRunWasMerge { return L("encoding.merge_running") }
        if vm.lastRunWasTrimOnly { return L("encoding.trim_running") }
        if worker.phase == "gif" { return L("encoding.gif_running") }
        if worker.phase == "check" {
            return L("encoding.pass_check_fmt", max(worker.pass, 1))
        }
        if worker.phase == "encode" {
            if vm.lastRunSizeLimitMB > 0 {
                return L("encoding.attempt_encode_fmt", max(worker.pass, 1))
            }
            return L("encoding.pass_encode_fmt", max(worker.pass, 1))
        }
        if worker.detailCode == "presearch_start" || worker.detailCode == "presearch_probe" {
            return L("encoding.presearch_running")
        }
        return L("encoding.analysis_running")
    }

    private func statusTint(for worker: WorkerStatus?) -> Color? {
        guard let worker else { return nil }
        switch worker.status {
        case "done": return .savings
        case "failed": return .red
        case "skipped": return .secondary
        case "cancelled": return .orange
        default: return nil
        }
    }

    private func verdictLabel(for verdict: String) -> String {
        switch verdict {
        case "early_exit": return L("encoding.verdict.early_exit")
        case "accepted": return L("encoding.verdict.accepted")
        case "too_low": return L("encoding.verdict.too_low")
        case "quality_short": return L("encoding.verdict.quality_short")
        case "poor_savings": return L("encoding.verdict.poor_savings")
        case "too_large": return L("encoding.verdict.too_large")
        default: return L("encoding.verdict.evaluated")
        }
    }

    private func elapsedString(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
