import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Step 5: what the run achieved.
struct CompletedStep: View {
    @ObservedObject var vm: WizardViewModel
    @Environment(\.openWindow) private var openWindow

    enum BatchFilter: String, CaseIterable {
        case all
        case success
        case skipped
        case failed

        var title: String {
            switch self {
            case .all: return L("completed.filter.all")
            case .success: return L("completed.filter.success")
            case .skipped: return L("completed.filter.skipped")
            case .failed: return L("completed.filter.failed")
            }
        }
    }

    @State private var selectedResultId: String?
    @State private var filter: BatchFilter = .all

    var body: some View {
        if let gif = vm.gifResult {
            gifView(gif)
        } else {
            batchOrSingleView
        }
    }

    // MARK: - GIF Studio Result

    private func gifView(_ gif: GifResult) -> some View {
        Group {
            if gif.isSuccess, let path = gif.output_path {
                let url = URL(fileURLWithPath: path)
                let exists = FileManager.default.fileExists(atPath: path)
                ScrollView {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            AnimatedImage(url: url)
                                .frame(maxWidth: 440, minHeight: 220, maxHeight: 340)
                                .aspectRatio(CGFloat(gif.width ?? 16) / CGFloat(max(gif.height ?? 9, 1)), contentMode: .fit)
                                .background(Color.black.opacity(0.85))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color(nsColor: .separatorColor))
                                )
                                .if(exists) { view in
                                    view.draggable(url)
                                        .onTapGesture { NSWorkspace.shared.open(url) }
                                        .contextMenu { outputContextMenu(url: url) }
                                }

                            if exists {
                                Label(L("completed.drag_hint"), systemImage: "arrow.up.right.square")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(L("completed.gif.created"), systemImage: "checkmark.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.savings)
                                Text(url.lastPathComponent)
                                    .font(.title3.weight(.semibold))
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Text(url.deletingLastPathComponent().path.replacingOccurrences(
                                    of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardBackground()

                            HStack(spacing: 10) {
                                StatTile(title: L("completed.tile.file_size"), value: formatBytes(gif.size_bytes ?? 0), tint: .primary)
                                StatTile(title: L("completed.tile.resolution"), value: "\(gif.width ?? 0) × \(gif.height ?? 0)", tint: .primary)
                                StatTile(title: L("completed.tile.frames"), value: gif.frames.map { "\($0)" } ?? "–", tint: .brandTeal)
                            }
                            .fixedSize(horizontal: false, vertical: true)

                            if let encoder = gif.encoder, !encoder.isEmpty {
                                HStack {
                                    Text(L("encoding.telemetry.encoder"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Chip(text: encoder, tint: .brandAccent)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .cardBackground()
                            }

                            if exists {
                                HStack(spacing: 8) {
                                    Button {
                                        NSWorkspace.shared.open(url)
                                    } label: {
                                        Label(L("action.open"), systemImage: "play.fill")
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button {
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    } label: {
                                        Label(L("action.reveal_in_finder"), systemImage: "folder")
                                    }

                                    ShareLink(item: url) {
                                        Label(L("action.share"), systemImage: "square.and.arrow.up")
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: 960)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
            } else if gif.status == "cancelled" {
                StatusHero(icon: "stop.circle.fill", tint: .orange, title: L("completed.outcome.cancelled.title"),
                           message: L("completed.gif.cancelled"), compact: true) { EmptyView() }
            } else {
                StatusHero(icon: "xmark.octagon.fill", tint: .red, title: L("completed.gif.failed_title"),
                           message: gif.reason ?? L("encoding.failed"), compact: true) { EmptyView() }
            }
        }
    }

    // MARK: - Single & Batch Studio Layout

    private var batchOrSingleView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !vm.queuedURLs.isEmpty {
                    queuedCard
                }

                if vm.batchResults.count == 1, let only = vm.batchResults.first {
                    singleResultStudio(only)
                } else {
                    batchResultStudio
                }
            }
            .frame(maxWidth: 1080)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Single File Studio

    private func singleResultStudio(_ result: BatchItemResult) -> some View {
        let outURL = existingOutputURL(for: result)
        let before = beforeBytes(for: result)
        let after = afterBytes(for: result)

        return HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                resultStagePreview(for: result, height: nil)

                if result.status == "success" {
                    beforeAfterSizeCard(result: result, before: before, after: after, outURL: outURL)
                }
            }
            .frame(width: 350)

            VStack(alignment: .leading, spacing: 14) {
                singleOutcomeHero(result: result, outURL: outURL)
                singleMetricTiles(for: result)

                if result.status != "success" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("completed.note"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(ResultRow.detailText(for: result))
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .cardBackground()
                }

                if result.status == "success" && (result.dolby_vision != nil || !(result.dropped ?? []).isEmpty) {
                    trackNoticesCard(for: result)
                }

                if let floor = vm.suggestedFloor, !vm.retryEligibleCandidates.isEmpty {
                    retryFloorBanner(floor: floor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func singleOutcomeHero(result: BatchItemResult, outURL: URL?) -> some View {
        let meta = outcomeMeta
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(meta.tint.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: meta.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(meta.tint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(meta.title)
                        .font(.title3.weight(.semibold))
                    Text(meta.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if result.status == "success" && !vm.lastRunWasMerge,
                   let saved = result.saved_bytes, saved > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("−\(formatBytes(saved))")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.savings)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        if let pct = result.saved_pct, pct > 0.5 {
                            Text(L("completed.smaller_fmt", Int(pct.rounded())))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }

            if result.status == "success", let outURL {
                Divider().opacity(0.6)
                HStack(spacing: 8) {
                    if let comp = comparison(for: result) {
                        Button {
                            openWindow(value: comp)
                        } label: {
                            Label(L("action.compare_before_after"), systemImage: "rectangle.split.2x1")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            NSWorkspace.shared.open(outURL)
                        } label: {
                            Label(L("action.play"), systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if comparison(for: result) != nil {
                        Button {
                            NSWorkspace.shared.open(outURL)
                        } label: {
                            Label(L("action.play"), systemImage: "play.fill")
                        }
                    }

                    ShareLink(item: outURL) {
                        Label(L("action.share"), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    @ViewBuilder
    private func singleMetricTiles(for result: BatchItemResult) -> some View {
        let durText = result.duration.map { formatDuration($0) } ?? "–"
        if result.status == "success" && vm.lastRunWasTrimOnly {
            let pctText = (result.saved_pct ?? 0) > 0.5
                ? L("detail.encode_saved_fmt", Int(result.saved_pct!.rounded()))
                : L("options.trim.no_reencode")
            HStack(spacing: 10) {
                StatTile(title: L("completed.tile.savings"), value: pctText, tint: .savings)
                StatTile(title: L("completed.tile.method"), value: L("completed.stream_copy"), tint: .brandTeal)
                StatTile(title: L("completed.tile.runtime"), value: durText, tint: .secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else if result.status == "success" && vm.lastRunWasMerge {
            HStack(spacing: 10) {
                StatTile(title: L("completed.tile.file_size"), value: mergedFileSizeText, tint: .primary)
                StatTile(title: L("completed.tile.clips"), value: "\(max(vm.lastRunMergeClipCount, 2))", tint: .primary)
                StatTile(title: L("completed.tile.method"), value: L("completed.stream_copy"), tint: .brandTeal)
                StatTile(title: L("completed.tile.runtime"), value: durText, tint: .secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else if result.status == "success" {
            let pctText = result.saved_pct.map { L("detail.encode_saved_fmt", Int($0.rounded())) } ?? "–"
            let ssimText = result.ssim.map { L("detail.encode_ssim_fmt", $0) }
                ?? (vm.lastRunSizeLimitMB > 0 ? L("completed.size_limit_badge") : "–")
            let qText = result.quality.map { L("detail.encode_q_fmt", $0) }
                ?? (vm.lastRunSizeLimitMB > 0 ? "≤ \(vm.lastRunSizeLimitMB) MB" : "–")
            HStack(spacing: 10) {
                StatTile(title: L("completed.tile.savings"), value: pctText, tint: .savings)
                StatTile(title: L("completed.tile.quality"), value: ssimText, tint: .brandTeal)
                StatTile(title: L("completed.tile.quality_level"), value: qText, tint: .primary)
                StatTile(title: L("completed.tile.runtime"), value: durText, tint: .secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Batch Studio Layout

    private var batchResultStudio: some View {
        let filtered = filteredBatchResults
        let selected = selectedBatchResult(from: filtered)
        let availableFilters = availableBatchFilters

        return VStack(alignment: .leading, spacing: 18) {
            batchOutcomeBanner

            if let floor = vm.suggestedFloor, !vm.retryEligibleCandidates.isEmpty {
                retryFloorBanner(floor: floor)
            }

            if !vm.batchResults.isEmpty {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(L("completed.results_fmt", filtered.count))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if availableFilters.count > 2 {
                                Picker(L("completed.filter.all"), selection: $filter) {
                                    ForEach(availableFilters, id: \.self) { f in
                                        Text(f.title).tag(f)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                            }
                        }

                        VStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.offset) { index, r in
                                if index > 0 { Divider().padding(.leading, 46) }
                                ResultRow(
                                    result: r,
                                    selected: selected?.id == r.id,
                                    compare: comparison(for: r).map { item in
                                        { openWindow(value: item) }
                                    }
                                )
                                .onTapGesture {
                                    selectedResultId = r.id
                                }
                            }
                        }
                        .cardBackground()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let selected {
                        batchInspectorColumn(for: selected)
                            .frame(width: 340)
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.upArrow) {
                    moveBatchSelection(in: filtered, current: selected, offset: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveBatchSelection(in: filtered, current: selected, offset: 1)
                    return .handled
                }
            }
        }
    }

    private func moveBatchSelection(in items: [BatchItemResult], current: BatchItemResult?, offset: Int) {
        guard !items.isEmpty else { return }
        if let current, let idx = items.firstIndex(where: { $0.id == current.id }) {
            let next = max(0, min(items.count - 1, idx + offset))
            selectedResultId = items[next].id
        } else {
            selectedResultId = items[0].id
        }
    }

    private var batchOutcomeBanner: some View {
        let meta = outcomeMeta
        let showBigSaved = vm.completedCount > 0 && !vm.wasCancelled && !vm.lastRunWasMerge && vm.actualSavedBytes > 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(meta.tint.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: meta.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(meta.tint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(meta.title)
                        .font(.title3.weight(.semibold))
                    Text(meta.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if showBigSaved {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("−\(formatBytes(vm.actualSavedBytes))")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.savings)
                            .monospacedDigit()
                        Text(L("completed.space_saved"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                Chip(text: L("completed.optimized_ratio_fmt", vm.completedCount, vm.totalToEncode),
                     icon: "checkmark.circle.fill",
                     tint: vm.completedCount > 0 ? .savings : .secondary,
                     monospaced: true)
                if averageSavedPctText != "–" {
                    Chip(text: L("completed.avg_fmt", averageSavedPctText), tint: .brandTeal, monospaced: true)
                }
                if vm.skippedCount > 0 {
                    Chip(text: L("completed.skipped_cnt_fmt", vm.skippedCount), tint: .secondary, monospaced: true)
                }
                if vm.failedCount > 0 {
                    Chip(text: L("completed.failed_cnt_fmt", vm.failedCount),
                         icon: "xmark.circle.fill", tint: .red, monospaced: true)
                }
                if let dur = totalBatchDurationText {
                    Chip(text: dur, icon: "clock", tint: .secondary, monospaced: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func batchInspectorColumn(for result: BatchItemResult) -> some View {
        let outURL = existingOutputURL(for: result)
        let before = beforeBytes(for: result)
        let after = afterBytes(for: result)

        return VStack(alignment: .leading, spacing: 12) {
            Text(L("completed.inspector"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            resultStagePreview(for: result, height: 165)

            if result.status == "success" {
                beforeAfterSizeCard(result: result, before: before, after: after, outURL: outURL)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        if let pct = result.saved_pct, pct > 0.5 {
                            Chip(text: L("detail.encode_saved_fmt", Int(pct.rounded())), tint: .savings, monospaced: true)
                        }
                        if let ssim = result.ssim {
                            Chip(text: L("detail.encode_ssim_fmt", ssim), tint: .brandTeal, monospaced: true)
                        }
                        if let q = result.quality {
                            Chip(text: L("detail.encode_q_fmt", q), tint: .brandAccent, monospaced: true)
                        }
                        if let dur = result.duration, dur > 0 {
                            Chip(text: formatDuration(dur), tint: .secondary, monospaced: true)
                        }
                    }

                    if let outURL {
                        HStack(spacing: 6) {
                            if let comp = comparison(for: result) {
                                Button {
                                    openWindow(value: comp)
                                } label: {
                                    Label(L("action.compare"), systemImage: "rectangle.split.2x1")
                                }
                                .controlSize(.small)
                            }
                            Button {
                                NSWorkspace.shared.open(outURL)
                            } label: {
                                Label(L("action.open"), systemImage: "play.fill")
                            }
                            .controlSize(.small)
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([outURL])
                            } label: {
                                Image(systemName: "folder")
                                    .accessibilityLabel(L("action.reveal_in_finder"))
                            }
                            .controlSize(.small)
                            .help(L("action.reveal_in_finder"))
                            ShareLink(item: outURL) {
                                Image(systemName: "square.and.arrow.up")
                                    .accessibilityLabel(L("action.share"))
                            }
                            .controlSize(.small)
                            .help(L("action.share"))
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()

                if result.dolby_vision != nil || !(result.dropped ?? []).isEmpty {
                    trackNoticesCard(for: result)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.filename ?? L("completed.file"))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(ResultRow.detailText(for: result))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .cardBackground()
            }
        }
    }

    // MARK: - Shared Result Subviews

    @ViewBuilder
    private func resultStagePreview(for result: BatchItemResult, height: CGFloat?) -> some View {
        let outURL = existingOutputURL(for: result)
        let previewURL = outURL ?? result.path.flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
        let title = outURL?.lastPathComponent ?? result.filename ?? L("completed.result")
        let badge: String? = {
            switch result.status {
            case "success":
                if vm.lastRunWasMerge { return L("completed.merge_badge") }
                if vm.lastRunWasTrimOnly { return L("completed.stream_copy") }
                if let pct = result.saved_pct, pct > 0.5 { return L("detail.encode_saved_fmt", Int(pct.rounded())) }
                return L("completed.optimized_badge")
            case "skipped": return L("encoding.skipped")
            case "cancelled": return L("encoding.cancelled")
            default: return L("encoding.failed")
            }
        }()

        if let previewURL {
            VStack(alignment: .leading, spacing: 6) {
                VideoStagePreview(
                    url: previewURL,
                    title: title,
                    duration: vm.candidate(forPath: result.path ?? "")?.duration_sec,
                    badge: badge,
                    height: height
                )
                .if(outURL != nil && result.status == "success") { view in
                    view.draggable(outURL!)
                        .onTapGesture { NSWorkspace.shared.open(outURL!) }
                        .contextMenu { outputContextMenu(url: outURL!) }
                        .help(L("completed.drag_hint"))
                }

                if outURL != nil && result.status == "success" {
                    Label(L("completed.drag_hint"), systemImage: "arrow.up.right.square")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func outputContextMenu(url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label(L("action.play"), systemImage: "play.fill")
        }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Label(L("action.reveal_in_finder"), systemImage: "folder")
        }
        Divider()
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        } label: {
            Label(L("action.copy_path"), systemImage: "doc.on.doc")
        }
    }

    private func beforeAfterSizeCard(result: BatchItemResult, before: Int64?, after: Int64?, outURL: URL?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if vm.lastRunWasMerge {
                HStack {
                    Text(L("completed.result"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(mergedFileSizeText)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            } else if let before, let after, before > 0 {
                HStack {
                    Text(L("completed.before_after"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(formatBytes(before)) → \(formatBytes(after))")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                CrunchMeterBar(fraction: min(1, max(0, Double(after) / Double(before))))
            }

            if let outURL {
                Divider().opacity(0.6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(outURL.lastPathComponent)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(outURL.deletingLastPathComponent().path.replacingOccurrences(
                        of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func trackNoticesCard(for result: BatchItemResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("completed.track_notices.title"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let dv = result.dolby_vision, let kept = dv.kept_as {
                Label(L("completed.dv_kept_fmt", dv.profile, kept),
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let dropped = result.dropped, !dropped.isEmpty {
                Label(L("completed.dropped_list_fmt", dropped.joined(separator: ", ")),
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func retryFloorBanner(floor: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "dial.medium.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("completed.retry.title_fmt", videoCount(vm.retryEligibleCandidates.count)))
                    .fontWeight(.medium)
                Text(L("completed.retry.sub_fmt", floor))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("completed.retry.button")) {
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

    private var queuedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.queuedURLs.count == 1
                     ? L("completed.queued.one")
                     : L("completed.queued.many_fmt", vm.queuedURLs.count))
                    .fontWeight(.medium)
                Text(vm.queuedURLs.prefix(3).map(\.lastPathComponent).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(L("completed.queued.action")) {
                vm.scanQueued()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .cardBackground()
    }

    // MARK: - Helpers

    private var outcomeMeta: (icon: String, tint: Color, title: String, message: String) {
        if vm.wasCancelled {
            return ("stop.circle.fill", .orange, L("completed.outcome.cancelled.title"),
                    L("completed.outcome.cancelled.msg_fmt", vm.completedCount, vm.totalToEncode))
        }
        if vm.completedCount == 0 && vm.failedCount == 0 && vm.skippedCount > 0 {
            return ("forward.circle.fill", .brandAccent, L("completed.outcome.nothing.title"),
                    L("completed.outcome.nothing.msg"))
        }
        if vm.completedCount == 0 {
            return ("xmark.octagon.fill", .red, L("completed.outcome.failed.title"),
                    L("completed.outcome.failed.msg"))
        }
        if vm.lastRunWasTrimOnly {
            return ("checkmark.circle.fill", .savings, L("completed.outcome.trimmed.title"),
                    L("completed.outcome.trimmed.msg"))
        }
        if vm.lastRunWasMerge {
            return ("checkmark.circle.fill", .savings, L("completed.outcome.merged.title"),
                    L("completed.outcome.merged.msg"))
        }
        let msg = vm.lastRunSizeLimitMB > 0
            ? L("completed.outcome.done.msg_limit_fmt", vm.lastRunSizeLimitMB)
            : vm.moveToTrash
            ? L("completed.outcome.done.msg_trash")
            : L("completed.outcome.done.msg_opt")
        return ("checkmark.circle.fill", .savings, L("completed.outcome.done.title"), msg)
    }

    private var availableBatchFilters: [BatchFilter] {
        var list: [BatchFilter] = [.all]
        if vm.batchResults.contains(where: { $0.status == "success" }) { list.append(.success) }
        if vm.batchResults.contains(where: { $0.status == "skipped" }) { list.append(.skipped) }
        if vm.batchResults.contains(where: { $0.status != "success" && $0.status != "skipped" }) {
            list.append(.failed)
        }
        return list
    }

    private var filteredBatchResults: [BatchItemResult] {
        switch filter {
        case .all:
            return vm.batchResults
        case .success:
            return vm.batchResults.filter { $0.status == "success" }
        case .skipped:
            return vm.batchResults.filter { $0.status == "skipped" }
        case .failed:
            return vm.batchResults.filter { $0.status != "success" && $0.status != "skipped" }
        }
    }

    private func selectedBatchResult(from items: [BatchItemResult]) -> BatchItemResult? {
        if let selectedResultId, let match = items.first(where: { $0.id == selectedResultId }) {
            return match
        }
        return items.first(where: { $0.status == "success" }) ?? items.first
    }

    private func existingOutputURL(for result: BatchItemResult) -> URL? {
        guard let path = result.output_path, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func fileSize(atPath path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }

    private func afterBytes(for result: BatchItemResult) -> Int64? {
        guard let path = result.output_path else { return nil }
        return fileSize(atPath: path)
    }

    private func beforeBytes(for result: BatchItemResult) -> Int64? {
        if let path = result.path, FileManager.default.fileExists(atPath: path),
           let disk = fileSize(atPath: path) {
            return disk
        }
        if let after = afterBytes(for: result), let saved = result.saved_bytes {
            return max(0, after + saved)
        }
        if let path = result.path, let cand = vm.candidate(forPath: path) {
            return Int64(cand.size_mb * 1024.0 * 1024.0)
        }
        return nil
    }

    private func comparison(for result: BatchItemResult) -> Comparison? {
        guard !vm.lastRunWasTrimOnly, !vm.lastRunWasMerge,
              result.status == "success", let source = result.path,
              let encoded = result.output_path, source != encoded,
              FileManager.default.fileExists(atPath: source),
              FileManager.default.fileExists(atPath: encoded) else { return nil }
        let offset = vm.lastRunTrim.flatMap { $0.path == source ? $0.start : nil } ?? 0
        return Comparison(source: URL(fileURLWithPath: source), encoded: URL(fileURLWithPath: encoded),
                          offset: offset)
    }

    private var mergedFileSizeText: String {
        if let path = vm.batchResults.first?.output_path, let size = fileSize(atPath: path) {
            return formatBytes(size)
        }
        return L("options.merge.one_file")
    }

    private var averageSavedPctText: String {
        let pcts = vm.batchResults
            .filter { $0.status == "success" }
            .compactMap(\.saved_pct)
            .filter { $0 > 0 }
        guard !pcts.isEmpty else { return "–" }
        let avg = pcts.reduce(0, +) / Double(pcts.count)
        return L("detail.encode_saved_fmt", Int(avg.rounded()))
    }

    private var totalBatchDurationText: String? {
        let total = vm.batchResults.compactMap(\.duration).reduce(0, +)
        return total > 0 ? formatDuration(total) : nil
    }
}

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

/// A GIF that plays: NSImageView animates GIFs, SwiftUI's Image does not.
struct AnimatedImage: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = NSImage(contentsOf: url)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}
