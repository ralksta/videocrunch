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
            return L("bottom.selection_fmt", vm.selectedCandidates.count, formatMB(vm.selectedEstimatedSavedMB))
        case .options where vm.isGif:
            return vm.gifEstimate.map { L("bottom.gif_fmt", formatBytes($0.estimated_bytes), $0.width, $0.height) }
                ?? (vm.isEstimatingGif ? L("bottom.gif_estimating") : nil)
        case .options where vm.isTrimOnly:
            return L("bottom.trim_only_fmt", formatMB(vm.selectedTotalAfterMB))
        case .options where vm.isMerge:
            return L("bottom.merge_fmt", vm.orderedMergeCandidates.count, formatMB(vm.selectedTotalMB))
        case .options:
            let time = vm.selectedRuntimeSec.map { L("bottom.runtime_fmt", formatDuration($0)) } ?? ""
            return L("bottom.options_fmt", formatMB(vm.selectedTotalAfterMB), formatMB(vm.selectedEstimatedSavedMB), time)
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
                    Label(L("action.cancel"), systemImage: "stop.fill")
                }
                .controlSize(.large)
                .disabled(!vm.isEncoding)
            } else if vm.currentStep == .completed, !vm.revealableURLs.isEmpty {
                Button {
                    vm.revealCurrentInFinder()
                } label: {
                    Label(L("action.reveal_in_finder"), systemImage: "folder")
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
                    Label(L("action.continue"), systemImage: "chevron.right")
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
                        Label(L("bottom.action.make_gif"), systemImage: "photo.stack")
                    } else if vm.isTrimOnly {
                        Label(L("bottom.action.trim_video"), systemImage: "scissors")
                    } else if vm.isMerge {
                        Label(L("bottom.action.merge"), systemImage: "film.stack")
                    } else {
                        Label(L("bottom.action.start_encode"), systemImage: "play.fill")
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
                    Label(L("bottom.action.new_videos"), systemImage: "plus")
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
