import AppKit
import SwiftUI

/// Step 5: what the run achieved.
struct CompletedStep: View {
    @ObservedObject var vm: WizardViewModel
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

    var body: some View {
        if let gif = vm.gifResult {
            gifView(gif)
        } else {
            batchView
        }
    }

    /// A GIF run: the GIF itself, playing, with what it weighs.
    private func gifView(_ gif: GifResult) -> some View {
        VStack(spacing: 18) {
            if gif.isSuccess, let path = gif.output_path {
                let url = URL(fileURLWithPath: path)
                AnimatedImage(url: url)
                    .frame(maxWidth: CGFloat(gif.width ?? 480), maxHeight: .infinity)
                    .aspectRatio(CGFloat(gif.width ?? 16) / CGFloat(max(gif.height ?? 9, 1)), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(radius: 6, y: 2)
                VStack(spacing: 4) {
                    Text(url.lastPathComponent)
                        .font(.headline)
                    Text("\(formatBytes(gif.size_bytes ?? 0)) · \(gif.width ?? 0) × \(gif.height ?? 0) · \(gif.frames ?? 0) Bilder")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Öffnen", systemImage: "eye")
                    }
                    ShareLink(item: url) {
                        Label("Teilen", systemImage: "square.and.arrow.up")
                    }
                }
            } else if gif.status == "cancelled" {
                StatusHero(icon: "stop.circle.fill", tint: .orange, title: "Abgebrochen",
                           message: "Es wurde kein GIF geschrieben.", compact: true) { EmptyView() }
            } else {
                StatusHero(icon: "xmark.octagon.fill", tint: .red, title: "GIF fehlgeschlagen",
                           message: gif.reason ?? "Unbekannter Fehler", compact: true) { EmptyView() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var batchView: some View {
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
