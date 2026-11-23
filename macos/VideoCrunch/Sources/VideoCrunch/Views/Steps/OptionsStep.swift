import AppKit
import SwiftUI

/// Step 3: how to encode the selection.
struct OptionsStep: View {
    @ObservedObject var vm: WizardViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSavePresetAlert = false
    @State private var newPresetName = ""

    /// Everything on one screen, laptop included: the summary on top, the
    /// video (or batch list) on the left, the settings on the right.
    var body: some View {
        VStack(spacing: 12) {
            if vm.isGif {
                gifSummary
            } else if vm.isTrimOnly {
                trimSummary
            } else if vm.isMerge {
                mergeSummary
            } else {
                savingsSummary
            }

            HStack(alignment: .top, spacing: 20) {
                if let target = vm.trimTarget, let duration = target.duration_sec {
                    TrimEditor(url: URL(fileURLWithPath: target.file_path), duration: duration,
                               start: $vm.trimStart, end: $vm.trimEnd)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .layoutPriority(1)
                    ScrollView {
                        settingsColumn
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.automatic)
                    .frame(width: 360)
                } else if !vm.selectedCandidates.isEmpty {
                    ScrollView {
                        batchSelectionColumn
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.automatic)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .layoutPriority(1)
                    ScrollView {
                        settingsColumn
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.automatic)
                    .frame(width: 360)
                } else {
                    ScrollView {
                        settingsColumn
                            .frame(maxWidth: 560)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear { vm.requestGifEstimate() }
        .onChange(of: vm.gifEstimateKey) { vm.requestGifEstimate() }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: 1100)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(L("options.preset.save_title"), isPresented: $showSavePresetAlert) {
            TextField(L("options.preset.name_placeholder"), text: $newPresetName)
            Button(L("action.save")) {
                vm.saveCurrentAsPreset(name: newPresetName)
                newPresetName = ""
            }
            Button(L("action.cancel"), role: .cancel) {
                newPresetName = ""
            }
        } message: {
            Text(L("options.preset.save_message"))
        }
    }

    private var settingsColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            if vm.trimTarget != nil {
                // One video: shrink it, trim it without re-encoding, or make a GIF of it.
                Picker(L("options.mode"), selection: $vm.outputMode) {
                    Label(L("options.mode.compress"), systemImage: "film").tag(OutputMode.video)
                    Label(L("options.mode.trim_only"), systemImage: "scissors").tag(OutputMode.trimOnly)
                    Label(L("options.mode.gif"), systemImage: "photo.stack").tag(OutputMode.gif)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if vm.selectedCandidates.count >= 2 {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(L("options.mode"), selection: $vm.outputMode) {
                        Label(L("options.mode.compress"), systemImage: "film").tag(OutputMode.video)
                        Label(L("options.mode.merge"), systemImage: "film.stack")
                            .tag(OutputMode.merge)
                            .disabled(!vm.canMerge)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(vm.mergeIncompatibilityReason ?? L("options.merge.tooltip"))
                    if let reason = vm.mergeIncompatibilityReason, !vm.canMerge {
                        Text(L("options.merge.impossible_fmt", reason))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: vm.outputMode) {
                    if vm.outputMode == .merge && !vm.canMerge {
                        vm.outputMode = .video
                    }
                }
            }
            if vm.isGif {
                gifSettings
            } else if vm.isTrimOnly {
                trimSettings
            } else if vm.isMerge {
                mergeSettings
            } else {
                videoSettings
            }
        }
    }

    private var gifSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            OptionSection(title: L("options.gif.width")) {
                Picker(L("options.gif.width"), selection: $vm.gifWidth) {
                    ForEach([320, 480, 640, 800], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(L("options.gif.width_sub"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            OptionSection(title: L("options.gif.fps")) {
                Picker(L("options.gif.fps"), selection: $vm.gifFPS) {
                    ForEach([10, 15, 20, 25], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(L("options.gif.fps_sub"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            OptionSection(title: L("options.gif.speed")) {
                Picker(L("options.gif.speed"), selection: $vm.gifSpeed) {
                    Text("½×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("2×").tag(2.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(vm.gifSpeed < 1 ? L("options.gif.speed_slow")
                     : vm.gifSpeed > 1 ? L("options.gif.speed_fast")
                     : L("options.gif.speed_normal"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            OptionSection(title: L("options.gif.quality")) {
                HStack {
                    Slider(value: $vm.gifQuality, in: 30...100, step: 5)
                    Text("\(Int(vm.gifQuality))")
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
                Text(L("options.gif.quality_sub"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let range = vm.gifRange, (range.end - range.start) / vm.gifSpeed > 15 {
                Label(L("options.gif.too_long_fmt", formatDuration((range.end - range.start) / vm.gifSpeed)),
                      systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var trimSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            OptionSection(title: L("options.trim.section")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("options.trim.heading"))
                        .font(.subheadline)
                    Text(L("options.trim.bullets"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            OptionSection(title: L("options.files.section")) {
                VStack(spacing: 0) {
                    SettingRow(
                        icon: "scissors",
                        tint: .orange,
                        title: L("options.trim.keep_title"),
                        subtitle: L("options.trim.keep_sub")
                    ) {
                        Toggle("", isOn: .constant(false))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(true)
                    }
                }
                .cardBackground()
            }
        }
    }

    /// Passthrough/Trim-only summary.
    private var trimSummary: some View {
        let before = vm.selectedTotalMB
        let after = vm.selectedTotalAfterMB
        let saved = vm.selectedEstimatedSavedMB
        let fraction = before > 0 ? after / before : 1
        let trimLen = max(0, vm.trimEnd - vm.trimStart)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.trimTarget?.filename ?? L("menu.video"))
                        .font(.headline)
                        .lineLimit(1)
                    Text(L("options.trim.summary_fmt", formatDuration(trimLen), formatMB(before), formatMB(after)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Label(L("options.trim.badge"), systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("−\(formatMB(saved))")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.savings)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: saved)
                    Text(before > 0 ? L("options.smaller_pct_fmt", Int((1 - fraction) * 100)) : L("options.trim.no_reencode"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            CrunchMeterBar(fraction: fraction)
        }
        .padding(14)
        .cardBackground()
    }

    /// The GIF's expected size, from a two-second sample.
    private var gifSummary: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("options.gif.from_fmt", vm.trimTarget?.filename ?? ""))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Group {
                    if let e = vm.gifEstimate {
                        Text(L("options.gif.details_fmt", e.width, e.height, e.frames, e.encoder))
                    } else if let range = vm.gifRange {
                        Text(L("options.gif.fallback_fmt", formatDuration((range.end - range.start) / vm.gifSpeed), vm.gifFPS))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let e = vm.gifEstimate {
                    Text(L("selection.inspector.approx_fmt", formatBytes(e.estimated_bytes)))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: e.estimated_bytes)
                } else {
                    Text("–")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                }
                HStack(spacing: 4) {
                    if vm.isEstimatingGif {
                        ProgressView().controlSize(.mini)
                    }
                    Text(vm.isEstimatingGif ? L("options.gif.estimating") : L("options.estimated"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .cardBackground()
    }

    /// The one line under the switches: what the choice above means.
    private var settingsNote: String {
        if vm.sizeLimitMB > 0 {
            return L("options.note.size_limit_fmt", vm.sizeLimitMB)
        }
        if vm.targetCodec != vm.scannedCodec {
            return L("options.note.scanned_codec_fmt", codecName(vm.scannedCodec))
        }
        if vm.targetCodec == "av1" {
            return L("options.note.av1")
        }
        switch vm.qualityBalance {
        case .high: return L("options.note.high")
        case .balanced: return L("options.note.balanced")
        case .compact: return L("options.note.compact")
        }
    }

    private var mergeSummary: some View {
        let clips = vm.orderedMergeCandidates
        let totalDuration = clips.compactMap(\.duration_sec).reduce(0, +)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("options.merge.title_fmt", videoCount(clips.count)))
                    .font(.headline)
                Text(L("options.merge.sub_fmt", formatDuration(totalDuration), formatMB(vm.selectedTotalMB)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Label(L("options.merge.badge"), systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(L("options.merge.one_file"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("_merged.mp4")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .cardBackground()
    }

    private var mergeSettings: some View {
        let clips = vm.orderedMergeCandidates
        return VStack(alignment: .leading, spacing: 14) {
            OptionSection(title: L("options.merge.section")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("options.merge.heading"))
                        .font(.subheadline)
                    Text(L("options.merge.bullets"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .cardBackground()
            }

            OptionSection(title: L("options.merge.order")) {
                VStack(spacing: 0) {
                    ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                        if index > 0 { Divider().padding(.leading, 38) }
                        HStack(spacing: 10) {
                            Text("\(index + 1).")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 20, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(clip.filename)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let d = clip.duration_sec {
                                    Text("\(formatDuration(d)) · \(formatMB(clip.size_mb))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                            Spacer()
                            HStack(spacing: 4) {
                                Button {
                                    vm.moveMergeClip(id: clip.id, offset: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .disabled(index == 0)
                                .help(L("options.merge.move_up"))
                                Button {
                                    vm.moveMergeClip(id: clip.id, offset: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .disabled(index == clips.count - 1)
                                .help(L("options.merge.move_down"))
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .cardBackground()
            }
        }
    }

    private var videoSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                HStack {
                    Text(L("options.preset.label"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Spacer()
                    Menu(vm.matchingPreset?.name ?? L("options.preset.custom")) {
                        ForEach(EncodePreset.builtIn) { preset in
                            Button {
                                vm.applyPreset(preset)
                            } label: {
                                if vm.matchingPreset?.id == preset.id {
                                    Label(preset.name, systemImage: "checkmark")
                                } else {
                                    Text(preset.name)
                                }
                            }
                        }
                        if !vm.customPresets.isEmpty {
                            Divider()
                            ForEach(vm.customPresets) { preset in
                                Button {
                                    vm.applyPreset(preset)
                                } label: {
                                    if vm.matchingPreset?.id == preset.id {
                                        Label(preset.name, systemImage: "checkmark")
                                    } else {
                                        Text(preset.name)
                                    }
                                }
                            }
                            Menu(L("settings.preset.delete")) {
                                ForEach(vm.customPresets) { preset in
                                    Button(preset.name, role: .destructive) {
                                        vm.deleteCustomPreset(id: preset.id)
                                    }
                                }
                            }
                        }
                        Divider()
                        Button(L("options.preset.save_current")) {
                            newPresetName = ""
                            showSavePresetAlert = true
                        }
                        Button(L("settings.reset_defaults")) {
                            vm.resetSettingsToDefaults()
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .help(L("options.preset.help"))

                Divider().padding(.leading, 12)

                VStack(alignment: .leading, spacing: 8) {
                    Picker(L("encoding.brief.goal"), selection: $vm.isSizeLimitMode) {
                        Text(L("options.goal.quality")).tag(false)
                        Text(L("options.goal.size_limit")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .help(L("options.goal.help"))

                    if vm.isSizeLimitMode {
                        Picker("Limit", selection: $vm.sizeLimitMB) {
                            ForEach(WizardViewModel.sizePresets, id: \.self) { mb in
                                Text(L("options.size_limit_fmt", mb))
                                    .tag(mb)
                                    .disabled(!vm.isSizeLimitUseful(mb))
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .help(L("options.size_limit_help"))
                    } else {
                        Picker("Balance", selection: $vm.qualityBalance) {
                            Text(QualityBalance.high.label).tag(QualityBalance.high)
                            Text(QualityBalance.balanced.label).tag(QualityBalance.balanced)
                            Text(QualityBalance.compact.label).tag(QualityBalance.compact)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .help(L("options.balance.help"))
                    }

                    Text(settingsNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)

                Divider()

                HStack {
                    Text(L("options.resolution.label"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Spacer()
                    if vm.isSizeLimitMode {
                        Text(L("options.resolution.auto"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(L("options.resolution.label"), selection: $vm.scaleHeight) {
                            Text(vm.originalResolutionLabel).tag(0)
                            Divider()
                            ForEach(ResolutionPreset.all) { preset in
                                Text(vm.resolutionPresetLabel(preset))
                                    .tag(preset.height)
                                    .disabled(!vm.canDownscale(to: preset.height))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .help(vm.isSizeLimitMode
                      ? L("options.resolution.help_auto")
                      : L("options.resolution.help_manual"))

                Divider().padding(.leading, 12)

                HStack {
                    Text(L("options.codec.label"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Spacer()
                    Picker(L("options.codec.label"), selection: $vm.targetCodec) {
                        Text(L("options.codec.hevc")).tag("hevc")
                        Text(L("options.codec.av1")).tag("av1")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .help(vm.targetCodec == "av1"
                      ? L("options.codec.help_av1")
                      : L("options.codec.help_hevc"))

                Divider().padding(.leading, 12)

                HStack {
                    Text(L("options.audio.label"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Spacer()
                    Picker(L("options.audio.label"), selection: $vm.audioMode) {
                        Text(L("options.audio.original")).tag("standard")
                        Text(L("options.audio.enhanced")).tag("enhanced")
                        Text(L("options.audio.none")).tag("none")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .help(vm.audioMode == "enhanced"
                      ? L("options.audio.help_enhanced")
                      : vm.audioMode == "none"
                      ? L("options.audio.help_none")
                      : L("options.audio.help_original"))
            }
            .cardBackground()

            OptionSection(title: L("options.files.section")) {
                VStack(spacing: 0) {
                    if !vm.downscaleOnlyUnselected.isEmpty {
                        SettingRow(
                            icon: "sparkles",
                            tint: .indigo,
                            title: L("options.downscale_worth_fmt", videoCount(vm.downscaleOnlyUnselected.count)),
                            subtitle: L("options.downscale_worth_sub_fmt",
                                        vm.downscaleOnlyUnselected.prefix(2).map(\.filename).joined(separator: ", "))
                        ) {
                            Button(L("options.take")) {
                                vm.takeDownscaleOnly()
                            }
                            .help(L("options.take_help"))
                        }
                        Divider().padding(.leading, 50)
                    }
                    if vm.hasTallCandidates && vm.sizeLimitMB == 0 {
                        SettingRow(
                            icon: "arrow.down.right.and.arrow.up.left",
                            tint: .blue,
                            title: vm.selectedNeedingDownscale > 0 && !vm.scaleTo1080p
                                ? L("options.scale1080.recommended")
                                : L("options.scale1080.title"),
                            subtitle: L("options.scale1080.sub_fmt", formatMB(vm.downscaleExtraSavedMB))
                        ) {
                            Toggle("", isOn: $vm.scaleTo1080p)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        .help(L("options.scale1080.help_fmt", videoCount(vm.tallCandidatesCount)))
                        Divider().padding(.leading, 50)
                    }
                    if vm.canHalveFrameRate {
                        SettingRow(
                            icon: "speedometer",
                            tint: .orange,
                            title: L("options.halffps.title"),
                            subtitle: vm.sizeLimitMB > 0
                                ? L("options.halffps.sub_limit")
                                : L("options.halffps.sub_saved_fmt", formatMB(vm.halfFrameRateExtraSavedMB))
                        ) {
                            Toggle("", isOn: $vm.halveFrameRate)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        .help(L("options.halffps.help"))
                        Divider().padding(.leading, 50)
                    }
                    SettingRow(
                        icon: "rectangle.compress.vertical",
                        tint: .teal,
                        title: L("options.cropbars.title"),
                        subtitle: L("options.cropbars.sub")
                    ) {
                        Toggle("", isOn: $vm.cropBars)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    // Under a size the original always stays: the small copy is for sending.
                    if vm.sizeLimitMB == 0 {
                        Divider().padding(.leading, 50)
                        SettingRow(
                            icon: "trash.fill",
                            tint: vm.moveToTrash && !vm.isTrimmed ? .red : .gray,
                            title: L("options.trash.title"),
                            subtitle: vm.isTrimmed
                                ? L("options.trash.sub_trim")
                                : vm.moveToTrash
                                ? L("options.trash.sub_on")
                                : L("options.trash.sub_off")
                        ) {
                            Toggle("", isOn: $vm.moveToTrash)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .disabled(vm.isTrimmed)
                        }
                    }
                }
                .cardBackground()
            }

            if vm.sizeLimitMB == 0 {
                previewCard
            }
        }
    }

    /// "See how it will look": a few seconds encoded with these settings.
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "eye.fill")
                    .foregroundStyle(Color.accentColor)
                Text(L("options.preview.title"))
                    .fontWeight(.medium)
                Spacer()
                if vm.previewingId != nil {
                    ProgressView()
                        .controlSize(.small)
                } else if vm.selectedCandidates.count == 1, let only = vm.selectedCandidates.first {
                    Button(L("action.preview")) {
                        vm.makePreview(for: only) { openWindow(value: $0) }
                    }
                } else {
                    Menu(L("action.preview")) {
                        ForEach(vm.selectedCandidates) { c in
                            Button(c.filename) {
                                vm.makePreview(for: c) { openWindow(value: $0) }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            Text(vm.previewError ?? L("options.preview.sub"))
                .font(.caption)
                .foregroundStyle(vm.previewError != nil ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .cardBackground()
    }

    /// Before/after at a glance: what the selection weighs now and after.
    private var savingsSummary: some View {
        let before = vm.selectedTotalMB
        let after = vm.selectedTotalAfterMB
        let saved = vm.selectedEstimatedSavedMB
        let fraction = before > 0 ? after / before : 1
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("options.selected_fmt", videoCount(vm.selectedCandidates.count)))
                        .font(.headline)
                    Text(L("options.before_after_fmt", formatMB(before), formatMB(after)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let runtime = vm.selectedRuntimeSec {
                        Label(L("options.runtime_fmt", formatDuration(runtime)), systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(L("options.runtime_help"))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("−\(formatMB(saved))")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.savings)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: saved)
                    Text(before > 0 ? L("options.smaller_pct_fmt", Int((1 - fraction) * 100)) : L("options.estimated"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            CrunchMeterBar(fraction: fraction)
        }
        .padding(14)
        .cardBackground()
    }

    /// Left column when multiple videos are queued: live per-clip estimate under current options.
    private var batchSelectionColumn: some View {
        let items = vm.isMerge ? vm.orderedMergeCandidates : vm.selectedCandidates
        let sectionTitle = vm.isMerge
            ? L("options.batch.order_title_fmt", items.count)
            : L("options.batch.selected_title_fmt", items.count)

        return OptionSection(title: sectionTitle) {
            VStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, c in
                    batchCandidateCard(index: index, candidate: c)
                }
            }
        }
    }

    private func batchCandidateCard(index: Int, candidate c: Candidate) -> some View {
        let afterMB = vm.estimatedAfterMB(for: c)
        let savedMB = max(0, c.size_mb - afterMB)

        return HStack(spacing: 12) {
            VideoThumbnail(url: URL(fileURLWithPath: c.file_path), duration: c.duration_sec)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if vm.isMerge {
                        Text("#\(index + 1)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.brandAccent)
                            .monospacedDigit()
                    }
                    Text(c.filename)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 5) {
                    Chip(text: c.codec.uppercased(),
                         tint: ["hevc", "h265", "av1"].contains(c.codec.lowercased()) ? .brandTeal : .secondary)
                    Chip(text: c.resolutionString,
                         tint: c.shortSide >= 2160 ? .brandAccent : .secondary)
                    Chip(text: c.sizeFormatted, monospaced: true)
                }
            }

            Spacer(minLength: 10)

            if vm.isMerge {
                Text(c.duration_sec.map { formatDuration($0) } ?? c.sizeFormatted)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(savedMB > 0.05 ? "−\(formatMB(savedMB))" : "±0 MB")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(savedMB > 0.05 ? Color.savings : Color.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(L("options.before_after_fmt", c.sizeFormatted, formatMB(afterMB)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Button {
                vm.inspect(URL(fileURLWithPath: c.file_path))
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.secondary.opacity(0.75))
            .help(L("candidate.media_info_help"))
            .accessibilityLabel("\(L("action.media_info")): \(c.filename)")
        }
        .padding(10)
        .cardBackground()
        .contextMenu {
            Button {
                vm.inspect(URL(fileURLWithPath: c.file_path))
            } label: {
                Label(L("action.media_info"), systemImage: "info.circle")
            }

            let fileURL = URL(fileURLWithPath: c.file_path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Label(L("action.reveal_in_finder"), systemImage: "folder")
                }
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(c.file_path, forType: .string)
            } label: {
                Label(L("action.copy_path"), systemImage: "doc.on.doc")
            }
        }
    }
}
