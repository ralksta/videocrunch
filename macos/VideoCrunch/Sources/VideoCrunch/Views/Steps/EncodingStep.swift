import SwiftUI

/// Step 4: the batch running.
struct EncodingStep: View {
    @ObservedObject var vm: WizardViewModel

    var body: some View {
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
}
