import SwiftUI

struct WizardView: View {
    @ObservedObject var vm: WizardViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar
            Divider()

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

            Divider()
            // Bottom Action Bar
            bottomBar
        }
        .frame(minWidth: 780, minHeight: 520)
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 24))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("videocrunch")
                    .font(.headline)
                    .fontWeight(.bold)
                if let url = vm.targetURL {
                    Text(url.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Step Indicator Pill
            stepIndicatorPill
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
    private var scanView: some View {
        VStack(spacing: 16) {
            Spacer()
            if let err = vm.errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundColor(.red)
                Text("Fehler beim Scannen")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(err)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            } else {
                ProgressView()
                    .scaleEffect(1.2)
                Text("Lese Metadaten...")
                    .font(.title3)
                    .fontWeight(.medium)
                Text("Analysiere Auflösung, Codec & Einsparpotenzial ohne Kodierung.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - Step 2: Selection Table
    private var selectionView: some View {
        VStack(spacing: 0) {
            // Quick Toolbar
            HStack {
                Text("\(vm.candidates.count) Videos analysiert")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Alle auswählen") { vm.selectAll() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.accentColor)

                Text("·").foregroundColor(.secondary)

                Button("Keine") { vm.deselectAll() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.05))

            // Candidates List
            if vm.candidates.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 44))
                        .foregroundColor(.green)
                    Text("Alles optimal!")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("Keine Videos über der 10%-Einsparschwelle gefunden.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(vm.candidates) { c in
                    let isSelected = vm.selectedIds.contains(c.id)
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { isSelected },
                            set: { _ in vm.toggleSelection(for: c.id) }
                        ))
                        .labelsHidden()

                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.filename)
                                .font(.body)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                Text(c.codec.uppercased())
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.2))
                                    .cornerRadius(4)
                                    .font(.caption2)
                                Text("\(c.resolutionString) · \(String(format: "%.1f", c.bitrate_mbps)) Mbit/s")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(c.reason)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .italic()
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("-\(c.savedFormatted)")
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundColor(.green)
                            Text("-\(String(format: "%.0f", c.estimated_saved_pct))%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("von \(c.sizeFormatted)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Step 3: Options View
    private var optionsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                savingsSummary

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
                        if vm.hasTallCandidates {
                            SettingRow(
                                icon: "arrow.down.right.and.arrow.up.left",
                                tint: .blue,
                                title: "Auf 1080p verkleinern",
                                subtitle: "\(videoCount(vm.tallCandidatesCount)) höher als 1080p. Spart meist am meisten, Seitenverhältnis bleibt."
                            ) {
                                Toggle("", isOn: $vm.scaleTo1080p)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                            }
                            Divider().padding(.leading, 54)
                        }
                        SettingRow(
                            icon: "trash.fill",
                            tint: vm.moveToTrash ? .red : .gray,
                            title: "Originale in den Papierkorb",
                            subtitle: vm.moveToTrash
                                ? "Erst nach bestandenem SSIM-Qualitätscheck. Aus dem Papierkorb wiederherstellbar."
                                : "Aus: Das Original bleibt neben der neuen _opt.mp4 liegen."
                        ) {
                            Toggle("", isOn: $vm.moveToTrash)
                                .toggleStyle(.switch)
                                .labelsHidden()
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
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("−\(formatMB(saved))")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
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

    // MARK: - Step 4: Encoding Live Status
    private var encodingView: some View {
        VStack(spacing: 16) {
            // Stats Banner
            HStack(spacing: 30) {
                Label("\(vm.completedCount) Fertig", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Label("\(vm.failedCount) Fehlgeschlagen", systemImage: "xmark.circle.fill")
                    .foregroundColor(vm.failedCount > 0 ? .red : .secondary)
                Spacer()
                Text("Gesamt: \(vm.totalToEncode)")
                    .foregroundColor(.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 20)
            .padding(.top, 14)

            // Worker List
            VStack(spacing: 10) {
                if vm.workers.isEmpty {
                    Text("Starte Encoding Engine...")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(Array(vm.workers.values.sorted(by: { $0.id < $1.id }))) { w in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Worker #\(w.id): \(w.file.isEmpty ? "Initialisiere..." : w.file)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Spacer()
                                if w.q > 0 {
                                    Text("Q=\(w.q)")
                                        .font(.caption2)
                                        .padding(.horizontal, 4)
                                        .background(Color.secondary.opacity(0.1))
                                        .cornerRadius(4)
                                }
                                Text("\(w.progress)%")
                                    .font(.caption)
                                    .fontWeight(.bold)
                            }
                            ProgressView(value: Double(w.progress), total: 100.0)
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }

            Spacer()

            // Console output disclosure
            DisclosureGroup("Live-Ausgabe") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(vm.logs.suffix(15), id: \.self) { line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 80)
                .background(Color.black.opacity(0.2))
                .cornerRadius(6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Step 5: Completed View
    private var completedView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Optimierung abgeschlossen!")
                .font(.title2)
                .fontWeight(.bold)

            VStack(spacing: 6) {
                Text("\(formatBytes(vm.actualSavedBytes)) Speicherplatz gespart.")
                    .font(.headline)
                    .foregroundColor(.green)
                Text("\(vm.completedCount) von \(vm.totalToEncode) Dateien erfolgreich optimiert.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if let floor = vm.suggestedFloor, !vm.retryEligibleCandidates.isEmpty {
                VStack(spacing: 8) {
                    Text("\(vm.retryEligibleCandidates.count) Datei(en) erreichten die SSIM-Schwelle nicht.")
                        .font(.caption)
                        .foregroundColor(.orange)

                    Button("Mit angepasstem Floor (\(String(format: "%.2f", floor))) erneut versuchen") {
                        vm.retryFailedWithNewFloor()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Bottom Action Bar
    private var bottomBar: some View {
        HStack {
            if vm.currentStep == .options {
                Button {
                    vm.backToCandidates()
                } label: {
                    Label("Zurück", systemImage: "chevron.left")
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            } else if vm.currentStep == .encoding {
                Button("Abbrechen") {
                    vm.cancelEncoding()
                }
                .foregroundColor(.red)
            }

            Spacer()

            if vm.currentStep == .candidateSelection {
                let count = vm.selectedCandidates.count
                Text("\(count) ausgewählt · ~\(formatMB(vm.selectedEstimatedSavedMB)) Ersparnis")
                    .font(.caption)
                    .foregroundColor(.secondary)

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
                Text("\(videoCount(vm.selectedCandidates.count)) · \(codecName(vm.targetCodec))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    vm.startEncoding()
                } label: {
                    Label("Encode starten", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else if vm.currentStep == .completed {
                Button("Schließen") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderedProminent)
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
