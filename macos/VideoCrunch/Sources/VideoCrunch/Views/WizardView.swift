import SwiftUI

struct WizardView: View {
    @ObservedObject var vm: WizardViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Main Content by Step
            Group {
                switch vm.currentStep {
                case .scanning:
                    ScanStep(vm: vm)
                case .candidateSelection:
                    SelectionStep(vm: vm)
                case .options:
                    OptionsStep(vm: vm)
                case .encoding:
                    EncodingStep(vm: vm)
                case .completed:
                    CompletedStep(vm: vm)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: vm.currentStep)

            // Nothing to act on while scanning or on the empty start screen.
            if vm.currentStep != .scanning {
                Divider()
                BottomBar(vm: vm)
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
        // Mac window chrome: what is open as the title, back and the step in
        // the title bar, the way Finder and Gifski place them.
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    goBack()
                } label: {
                    Label("Zurück", systemImage: "chevron.left")
                }
                .help("Zurück (⌘[)")
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!canGoBack)
            }
            ToolbarItem(placement: .principal) {
                stepIndicatorPill
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    vm.chooseAndOpen()
                } label: {
                    Label("Hinzufügen", systemImage: "plus")
                }
                .help("Videos oder Ordner hinzufügen (⌘O)")
            }
        }
        // Drop anywhere, in any step: before a selection it starts, during
        // one it adds, during an encode it waits for the next run.
        .dropDestination(for: URL.self) { urls, _ in
            vm.open(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay {
                        Label(dropHint, systemImage: "plus.circle.fill")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    @State private var dropTargeted = false

    private var dropHint: String {
        switch vm.currentStep {
        case .candidateSelection, .options: return "Zur Auswahl hinzufügen"
        case .encoding: return "Für den nächsten Durchlauf vormerken"
        default: return "Loslassen zum Prüfen"
        }
    }

    private var targetDescription: String? {
        switch vm.targetURLs.count {
        case 0: return nil
        case 1: return vm.targetURLs[0].path
        default:
            let names = vm.targetURLs.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
            return vm.targetURLs.count > 3 ? "\(names) und \(vm.targetURLs.count - 3) weitere" : names
        }
    }

    // MARK: - Subviews

    private var windowTitle: String {
        targetDescription.map { vm.targetURLs.count == 1 ? vm.targetURLs[0].lastPathComponent : $0 }
            ?? "VideoCrunch"
    }

    /// Where the opened item lives, as Finder would abbreviate it.
    private var windowSubtitle: String {
        guard let first = vm.targetURLs.first else { return "" }
        let folder = vm.targetURLs.count == 1 ? first.deletingLastPathComponent() : first
        return (folder.path as NSString).abbreviatingWithTildeInPath
    }

    private var canGoBack: Bool {
        switch vm.currentStep {
        case .options, .candidateSelection: return true
        case .scanning: return vm.errorMessage != nil
        default: return false
        }
    }

    private func goBack() {
        switch vm.currentStep {
        case .options: vm.backToCandidates()
        case .candidateSelection, .scanning: vm.startOver()
        default: break
        }
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
}
