import QuickLook
import SwiftUI

/// Step 2: the candidates, with what each is expected to save.
struct SelectionStep: View {
    @ObservedObject var vm: WizardViewModel

    @State private var previewURL: URL?
    @State private var hoveredCandidate: String?

    /// Space previews the row under the pointer, as in Finder.
    private func previewHovered() {
        guard let id = hoveredCandidate ?? vm.candidates.first?.id else { return }
        previewURL = previewURL == nil ? URL(fileURLWithPath: id) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Button("Vorschau", action: previewHovered)
                .keyboardShortcut(.space, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text((vm.candidates.count == 1 ? "1 Kandidat" : "\(vm.candidates.count) Kandidaten")
                         + " · \(vm.recommendedIds.count) empfohlen")
                        .font(.headline)
                    Text("Videos, die mindestens 10 % kleiner würden")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if vm.isScanning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Prüfe weitere …")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let notice = vm.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button("Empfohlene") { vm.selectRecommended() }
                    .disabled(vm.selectedIds == vm.recommendedIds)
                    .help("Nur die Videos, bei denen sich das Encodieren voraussichtlich lohnt")
                Button("Alle") { vm.selectAll() }
                    .disabled(vm.selectedIds.count == vm.candidates.count)
                Button("Keine") { vm.deselectAll() }
                    .disabled(vm.selectedIds.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider()

            if vm.candidates.isEmpty {
                StatusHero(icon: "checkmark.seal.fill", tint: .green,
                           title: "Alles optimal",
                           message: "Kein Video würde um mindestens 10 % kleiner. Hier gibt es nichts zu holen.") {
                    EmptyView()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(vm.candidates) { c in
                            CandidateRow(candidate: c, selected: vm.selectedIds.contains(c.id),
                                         toggle: { vm.toggleSelection(for: c.id) },
                                         preview: { previewURL = URL(fileURLWithPath: c.file_path) },
                                         hover: { inside in hoveredCandidate = inside ? c.id : nil })
                        }
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .quickLookPreview($previewURL)
    }
}
