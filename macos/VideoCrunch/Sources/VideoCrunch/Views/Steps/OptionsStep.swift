import SwiftUI

/// Step 3: how to encode the selection.
struct OptionsStep: View {
    @ObservedObject var vm: WizardViewModel
    @Environment(\.openWindow) private var openWindow

    /// Everything on one screen, laptop included: the summary on top, the
    /// video (when one is trimmed) on the left, the settings on the right.
    /// Choices are compact switches with one line of explanation; the
    /// settings column scrolls on its own only in a very small window.
    var body: some View {
        VStack(spacing: 16) {
            if vm.isGif {
                gifSummary
            } else {
                savingsSummary
            }

            HStack(alignment: .top, spacing: 16) {
                if let target = vm.trimTarget, let duration = target.duration_sec {
                    TrimEditor(url: URL(fileURLWithPath: target.file_path), duration: duration,
                               start: $vm.trimStart, end: $vm.trimEnd)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .layoutPriority(1)
                    ScrollView {
                        settingsColumn
                    }
                    .scrollIndicators(.automatic)
                    .frame(width: 340)
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
        .padding(.vertical, 16)
        .frame(maxWidth: 1100)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            if vm.trimTarget != nil {
                // One video: shrink it, or make a GIF of it, the Gifski way.
                Picker("Ergebnis", selection: $vm.outputMode) {
                    Label("Video verkleinern", systemImage: "film").tag(OutputMode.video)
                    Label("GIF erstellen", systemImage: "photo.stack").tag(OutputMode.gif)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if vm.isGif {
                gifSettings
            } else {
                videoSettings
            }
        }
    }

    private var gifSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            OptionSection(title: "Breite") {
                Picker("Breite", selection: $vm.gifWidth) {
                    ForEach([320, 480, 640, 800], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text("Pixel. Kleiner wird nie hochskaliert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            OptionSection(title: "Bildrate") {
                Picker("Bildrate", selection: $vm.gifFPS) {
                    ForEach([10, 15, 20, 25], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text("Bilder pro Sekunde. Mehr wirkt flüssiger und wiegt mehr.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            OptionSection(title: "Tempo") {
                Picker("Tempo", selection: $vm.gifSpeed) {
                    Text("½×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("2×").tag(2.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(vm.gifSpeed < 1 ? "Zeitlupe: doppelt so lang, doppelt so viele Bilder."
                     : vm.gifSpeed > 1 ? "Zeitraffer: halb so lang, halb so groß."
                     : "So schnell wie das Video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            OptionSection(title: "Qualität") {
                HStack {
                    Slider(value: $vm.gifQuality, in: 30...100, step: 5)
                    Text("\(Int(vm.gifQuality))")
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
                Text("Weniger Qualität: kleinere Datei, mehr Bildrauschen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let range = vm.gifRange, (range.end - range.start) / vm.gifSpeed > 15 {
                Label("\(formatDuration((range.end - range.start) / vm.gifSpeed)) sind lang für ein GIF – links kürzen.",
                      systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The GIF's expected size, from a two-second sample.
    private var gifSummary: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("GIF aus \(vm.trimTarget?.filename ?? "")")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Group {
                    if let e = vm.gifEstimate {
                        Text("\(e.width) × \(e.height) · \(e.frames) Bilder · \(e.encoder)")
                    } else if let range = vm.gifRange {
                        Text("\(formatDuration((range.end - range.start) / vm.gifSpeed)) · \(vm.gifFPS) Bilder/s")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let e = vm.gifEstimate {
                    Text("ca. \(formatBytes(e.estimated_bytes))")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                } else {
                    Text("–")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                }
                HStack(spacing: 4) {
                    if vm.isEstimatingGif {
                        ProgressView().controlSize(.mini)
                    }
                    Text(vm.isEstimatingGif ? "schätze …" : "geschätzt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .cardBackground()
    }

    private var videoSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            OptionSection(title: "Codec") {
                Picker("Codec", selection: $vm.targetCodec) {
                    Text("HEVC / H.265").tag("hevc")
                    Text("AV1 (experimentell)").tag("av1")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(vm.targetCodec == "av1"
                     ? "Kleinere Dateien, deutlich langsamer. Braucht neuere Geräte."
                     : "Hardware-Encoder, schnell. Läuft auf praktisch jedem Gerät.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if vm.targetCodec != vm.scannedCodec {
                    Label("Die Ersparnis oben wurde für \(codecName(vm.scannedCodec)) geschätzt.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            OptionSection(title: "Audio") {
                Picker("Audio", selection: $vm.audioMode) {
                    Text("Original").tag("standard")
                    Text("Angleichen").tag("enhanced")
                    Text("Ohne Ton").tag("none")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(vm.audioMode == "enhanced"
                     ? "Lautheit auf −16 LUFS: leise Handyvideos werden hörbar, laute gezähmt."
                     : vm.audioMode == "none"
                     ? "Die neue Datei ist stumm."
                     : "Der Ton bleibt, wie er ist. Nur neu kodiert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                                + " – ohne Verkleinern unter 20 %."
                        ) {
                            Button("Mitnehmen") {
                                vm.takeDownscaleOnly()
                            }
                            .help("Auswählen und auf 1080p verkleinern")
                        }
                        Divider().padding(.leading, 50)
                    }
                    if vm.hasTallCandidates {
                        SettingRow(
                            icon: "arrow.down.right.and.arrow.up.left",
                            tint: .blue,
                            title: vm.selectedNeedingDownscale > 0 && !vm.scaleTo1080p
                                ? "Auf 1080p – empfohlen"
                                : "Auf 1080p verkleinern",
                            subtitle: "Spart zusätzlich ca. \(formatMB(vm.downscaleExtraSavedMB))."
                        ) {
                            Toggle("", isOn: $vm.scaleTo1080p)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        .help("\(videoCount(vm.tallCandidatesCount)) über 1080p. Das Seitenverhältnis bleibt.")
                        Divider().padding(.leading, 50)
                    }
                    if vm.canHalveFrameRate {
                        SettingRow(
                            icon: "speedometer",
                            tint: .orange,
                            title: "Auf 30 Bilder/s",
                            subtitle: "Spart zusätzlich ca. \(formatMB(vm.halfFrameRateExtraSavedMB)). Zeitlupen bleiben."
                        ) {
                            Toggle("", isOn: $vm.halveFrameRate)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        .help("60-fps-Videos werden zu 30, 50 zu 25. Schnelle Bewegung wirkt etwas weniger flüssig.")
                        Divider().padding(.leading, 50)
                    }
                    SettingRow(
                        icon: "rectangle.compress.vertical",
                        tint: .teal,
                        title: "Schwarze Balken abschneiden",
                        subtitle: "Nur wo welche sind. Das Bild selbst bleibt ganz."
                    ) {
                        Toggle("", isOn: $vm.cropBars)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    Divider().padding(.leading, 50)
                    SettingRow(
                        icon: "trash.fill",
                        tint: vm.moveToTrash && !vm.isTrimmed ? .red : .gray,
                        title: "Originale in den Papierkorb",
                        subtitle: vm.isTrimmed
                            ? "Beim Kürzen bleibt das Original erhalten."
                            : vm.moveToTrash
                            ? "Erst nach bestandenem Qualitätscheck."
                            : "Aus: Original bleibt neben der _opt.mp4."
                    ) {
                        Toggle("", isOn: $vm.moveToTrash)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(vm.isTrimmed)
                    }
                }
                .cardBackground()
            }

            previewCard
        }
    }

    /// "So wird es aussehen": a few seconds encoded with these settings,
    /// judged by eye before the full run.
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "eye.fill")
                    .foregroundStyle(Color.accentColor)
                Text("So wird es aussehen")
                    .fontWeight(.medium)
                Spacer()
                if vm.previewingId != nil {
                    ProgressView()
                        .controlSize(.small)
                } else if vm.selectedCandidates.count == 1, let only = vm.selectedCandidates.first {
                    Button("Vorschau") {
                        vm.makePreview(for: only) { openWindow(value: $0) }
                    }
                } else {
                    Menu("Vorschau") {
                        ForEach(vm.selectedCandidates) { c in
                            Button(c.filename) {
                                vm.makePreview(for: c) { openWindow(value: $0) }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            Text(vm.previewError
                 ?? (vm.previewingId != nil
                     ? "Erstelle Vorschau …"
                     : "Kodiert die schwierigste Stelle in Sekunden – zum Prüfen vor dem Encode."))
                .font(.caption)
                .foregroundStyle(vm.previewError == nil ? Color.secondary : Color.orange)
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
                        .font(.system(size: 22, weight: .bold, design: .rounded))
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
            .frame(height: 6)
            .accessibilityLabel("Danach ca. \(Int(fraction * 100)) % der heutigen Größe")
        }
        .padding(14)
        .cardBackground()
    }
}
