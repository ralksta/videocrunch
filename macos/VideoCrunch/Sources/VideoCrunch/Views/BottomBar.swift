import AppKit
import SwiftUI

/// The bar under every step but the scan: what the selection comes to,
/// and the button that moves on.
struct BottomBar: View {
    @ObservedObject var vm: WizardViewModel

    /// What the selection will come to — always in view next to the button
    /// that starts it, like Gifski's "Estimated size".
    private var bottomInfo: String? {
        switch vm.currentStep {
        case .candidateSelection:
            return "\(vm.selectedCandidates.count) ausgewählt · ca. −\(formatMB(vm.selectedEstimatedSavedMB))"
        case .options where vm.isGif:
            return vm.gifEstimate.map { "GIF ca. \(formatBytes($0.estimated_bytes)) · \($0.width) × \($0.height)" }
                ?? (vm.isEstimatingGif ? "Schätze GIF-Größe …" : nil)
        case .options:
            let time = vm.selectedRuntimeSec.map { " · dauert \(formatDuration($0))" } ?? ""
            return "Ergebnis ca. \(formatMB(vm.selectedTotalAfterMB)) · −\(formatMB(vm.selectedEstimatedSavedMB))" + time
        default:
            return nil
        }
    }

    var body: some View {
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
                    let gif = vm.gifResult?.output_path.map { URL(fileURLWithPath: $0) }
                    NSWorkspace.shared.activateFileViewerSelecting(gif.map { [$0] } ?? vm.targetURLs)
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
                    if vm.isGif {
                        Label("GIF erstellen", systemImage: "photo.stack")
                    } else {
                        Label("Encode starten", systemImage: "play.fill")
                    }
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
