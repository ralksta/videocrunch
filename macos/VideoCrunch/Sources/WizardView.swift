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
        Form {
            Section(header: Text("Zusammenfassung der Auswahl").font(.headline)) {
                HStack {
                    Label("\(vm.selectedCandidates.count) Videos ausgewählt", systemImage: "video.fill")
                    Spacer()
                    Text("Erwartete Ersparnis: ~\(formatMB(vm.selectedEstimatedSavedMB))")
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                }
            }

            Section(header: Text("Optimierungs-Optionen").font(.headline)) {
                if vm.hasTallCandidates {
                    Toggle(isOn: $vm.scaleTo1080p) {
                        VStack(alignment: .leading) {
                            Text("\(vm.tallCandidatesCount) Dateien sind höher als 1080p: Auf 1080p verkleinern?")
                                .fontWeight(.medium)
                            Text("Spart meist am meisten Platz, behält Seitenverhältnis bei.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }

                Toggle(isOn: $vm.moveToTrash) {
                    VStack(alignment: .leading) {
                        Text("Originale nach erfolgreichem Encode in Papierkorb legen?")
                            .fontWeight(.medium)
                        Text("Wird erst verschoben, nachdem der SSIM-Qualitätscheck bestanden wurde.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                Picker("Audio-Modus", selection: $vm.audioMode) {
                    Text("Enhanced (-16 LUFS, optimierte Dynamik)").tag("enhanced")
                    Text("Standard (Lautstärke unverändert)").tag("standard")
                }

                Picker("Ziel-Codec", selection: $vm.targetCodec) {
                    Text("HEVC / H.265 (Hardware VideoToolbox)").tag("hevc")
                    Text("AV1 (Modern)").tag("av1")
                }
            }
        }
        .padding(30)
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
                Button("Zurück") {
                    vm.backToCandidates()
                }
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

                Button("Weiter zur Konfiguration") {
                    vm.proceedToOptions()
                }
                .buttonStyle(.borderedProminent)
                .disabled(count == 0)
            } else if vm.currentStep == .options {
                Button("Start Crunch 🚀") {
                    vm.startEncoding()
                }
                .buttonStyle(.borderedProminent)
            } else if vm.currentStep == .completed {
                Button("Schließen") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.05))
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
