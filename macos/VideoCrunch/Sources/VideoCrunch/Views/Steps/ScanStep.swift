import SwiftUI

/// Step 1: what to open, the scan running, or why it failed.
struct ScanStep: View {
    @ObservedObject var vm: WizardViewModel

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        if let err = vm.errorMessage {
            StatusHero(icon: "exclamationmark.triangle.fill", tint: .orange,
                       title: "Scan fehlgeschlagen", message: err) {
                if !vm.targetURLs.isEmpty {
                    Button {
                        vm.startScan(for: vm.targetURLs)
                    } label: {
                        Label("Erneut scannen", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.large)
                }
            }
        } else if vm.targetURLs.isEmpty {
            StatusHero(icon: "film.stack", tint: .accentColor,
                       title: "Videos auswählen",
                       message: "Zieh Videos oder Ordner hierher oder aufs Dock-Symbol – oder wähle sie aus. Es wird erst kodiert, wenn du es bestätigst.") {
                Button {
                    vm.chooseAndOpen()
                } label: {
                    Label("Videos oder Ordner wählen …", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        } else {
            StatusHero(icon: "magnifyingglass", tint: .accentColor,
                       title: "Analysiere Videos …",
                       message: "Liest Auflösung, Codec und Bitrate. Dabei wird nichts kodiert.") {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}
