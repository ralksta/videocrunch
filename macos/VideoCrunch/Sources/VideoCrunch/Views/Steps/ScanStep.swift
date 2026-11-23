import AppKit
import SwiftUI

/// Step 1: what to open, the scan running, or why it failed.
struct ScanStep: View {
    @ObservedObject var vm: WizardViewModel
    var isDropTargeted: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if let err = vm.errorMessage {
            StatusHero(icon: "exclamationmark.triangle.fill", tint: .orange,
                       title: L("scan.failed"), message: err) {
                if !vm.targetURLs.isEmpty {
                    Button {
                        vm.startScan(for: vm.targetURLs)
                    } label: {
                        Label(L("scan.retry"), systemImage: "arrow.clockwise")
                    }
                    .controlSize(.large)
                }
            }
        } else if vm.targetURLs.isEmpty {
            emptyDropStage
        } else {
            scanningStage
        }
    }

    private var emptyDropStage: some View {
        VStack(spacing: 16) {
            VStack(spacing: 18) {
                CrunchMark(size: 64, squeeze: isDropTargeted ? 1.0 : 0.0)

                VStack(spacing: 6) {
                    Text(isDropTargeted ? L("scan.drop_release") : L("app.name"))
                        .font(.title2.weight(.semibold))
                    Text(L("scan.subtitle"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                Button {
                    vm.chooseAndOpen()
                } label: {
                    Label(L("scan.choose_button"), systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                HStack(spacing: 6) {
                    Chip(text: L("scan.chip.codecs"), tint: .brandTeal)
                    Chip(text: L("scan.chip.ssim"), tint: .brandAccent)
                    Chip(text: L("scan.chip.modes"), tint: .secondary)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: 560)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        isDropTargeted
                            ? Color.brandTeal.opacity(colorScheme == .dark ? 0.10 : 0.06)
                            : Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.44 : 0.70)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isDropTargeted
                            ? Color.brandTeal
                            : Color(nsColor: .separatorColor).opacity(contrast == .increased ? 1.0 : 0.9),
                        style: StrokeStyle(lineWidth: isDropTargeted ? 1.75 : (contrast == .increased ? 1.25 : 1.0),
                                           dash: isDropTargeted ? [7, 5] : [5, 5])
                    )
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isDropTargeted)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("scan.a11y.drop_target"))

            if vm.lifetimeStats.encodedCount > 0 || !vm.recentEncodes.isEmpty {
                workbenchHistoryCard
            }
        }
        .padding(24)
    }

    private var workbenchHistoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(vm.recentEncodes.isEmpty ? L("scan.history.balance") : L("scan.history.recent"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if vm.lifetimeStats.totalSavedBytes >= 1_000_000 {
                    Chip(
                        text: L("scan.history.total_fmt",
                                formatBytes(vm.lifetimeStats.totalSavedBytes),
                                vm.lifetimeStats.encodedCount),
                        tint: .brandTeal,
                        monospaced: true
                    )
                }
            }

            if !vm.recentEncodes.isEmpty {
                Divider().opacity(0.55)
                VStack(spacing: 7) {
                    ForEach(vm.recentEncodes) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.savings)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.filename)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                let meta = [
                                    entry.height.map { "\($0)p" },
                                    entry.ssim.map { L("detail.encode_ssim_fmt", $0) }
                                ].compactMap { $0 }.joined(separator: " · ")
                                if !meta.isEmpty {
                                    Text(meta)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                            Spacer(minLength: 8)
                            Text(L("scan.history.entry_saved_fmt",
                                   Int(entry.savedPct.rounded()),
                                   formatBytes(entry.savedBytes)))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.savings)
                                .monospacedDigit()
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.filename, forType: .string)
                            } label: {
                                Label(L("action.copy_filename"), systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .cardBackground()
    }

    private var scanningStage: some View {
        let targetNames = vm.targetURLs.prefix(2).map(\.lastPathComponent).joined(separator: ", ")
        let extraCount = vm.targetURLs.count - 2
        let targetLine = extraCount > 0 ? L("scan.running.more_fmt", targetNames, extraCount) : targetNames

        return VStack(spacing: 14) {
            CrunchMark(size: 62, squeeze: 0.25, scanning: true)
            Text(L("scan.running.title"))
                .font(.title2.weight(.semibold))
            Text(L("scan.running.subtitle"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !targetLine.isEmpty {
                Text(targetLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
            CrunchProgressBar(fraction: 0, active: true, indeterminate: true, height: 5)
                .frame(width: 240)
                .padding(.top, 4)
        }
        .padding(32)
    }
}
