import SwiftUI

struct WizardView: View {
    @ObservedObject var vm: WizardViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var stepNamespace

    var body: some View {
        VStack(spacing: 0) {
            // Main Content by Step
            Group {
                switch vm.currentStep {
                case .scanning:
                    ScanStep(vm: vm, isDropTargeted: dropTargeted)
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
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: vm.currentStep)

            // Nothing to act on while scanning or on the empty start screen.
            if vm.currentStep != .scanning {
                Divider()
                BottomBar(vm: vm)
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .background {
            ZStack(alignment: .top) {
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                LinearGradient(
                    colors: [
                        Color.brandAccent.opacity(colorScheme == .dark ? 0.045 : 0.022),
                        Color.clear,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 180)
                .allowsHitTesting(false)
            }
        }
        // Mac window chrome: what is open as the title, back and the step in
        // the title bar, the way Finder and Gifski place them.
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    vm.goBack()
                } label: {
                    Label(L("action.back"), systemImage: "chevron.left")
                }
                .help(L("toolbar.back_help"))
                .disabled(!vm.canGoBack)
            }
            ToolbarItem(placement: .principal) {
                stepIndicatorPill
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    vm.chooseAndOpen()
                } label: {
                    Label(L("action.add"), systemImage: "plus")
                }
                .help(L("toolbar.add_help"))
            }
        }
        // Drop anywhere, in any step: before a selection it starts, during
        // one it adds, during an encode it waits for the next run.
        .dropDestination(for: URL.self) { urls, _ in
            if !urls.isEmpty {
                Haptics.tap(.alignment)
            }
            vm.open(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted && !(vm.currentStep == .scanning && vm.targetURLs.isEmpty) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.brandTeal, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .background(Color.brandTeal.opacity(0.06))
                    .overlay {
                        HStack(spacing: 10) {
                            CrunchMark(size: 24, squeeze: 1)
                            Text(dropHint)
                                .font(.callout.weight(.semibold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
                    }
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $vm.inspectedTarget) { target in
            MediaInspectorSheet(
                url: target.url,
                inspection: vm.inspection,
                isLoading: vm.isInspecting,
                error: vm.inspectionError,
                onClose: { vm.closeInspector() }
            )
        }
    }

    @State private var dropTargeted = false

    private var dropHint: String {
        switch vm.currentStep {
        case .candidateSelection, .options: return L("drop.hint.add")
        case .encoding: return L("drop.hint.queue")
        default: return L("drop.hint.scan")
        }
    }

    private var targetDescription: String? {
        switch vm.targetURLs.count {
        case 0: return nil
        case 1: return vm.targetURLs[0].path
        default:
            let names = vm.targetURLs.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
            return vm.targetURLs.count > 3 ? L("nav.more_items_fmt", names, vm.targetURLs.count - 3) : names
        }
    }

    // MARK: - Subviews

    private var windowTitle: String {
        targetDescription.map { vm.targetURLs.count == 1 ? vm.targetURLs[0].lastPathComponent : $0 }
            ?? L("app.name")
    }

    /// Where the opened item lives, as Finder would abbreviate it.
    private var windowSubtitle: String {
        guard let first = vm.targetURLs.first else { return "" }
        let folder = vm.targetURLs.count == 1 ? first.deletingLastPathComponent() : first
        return (folder.path as NSString).abbreviatingWithTildeInPath
    }

    private var stepIndicatorPill: some View {
        let steps: [(step: WizardStep, title: String)] = [
            (.scanning, L("step.scan")),
            (.candidateSelection, L("step.selection")),
            (.options, L("step.options")),
            (.encoding, L("step.encode")),
            (.completed, L("step.completed")),
        ]
        let activeIdx = steps.firstIndex(where: { $0.step == vm.currentStep }) ?? 0

        return HStack(spacing: 2) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, item in
                let isActive = idx == activeIdx
                let isDone = idx < activeIdx
                let canJumpBack = vm.canGoBack && isDone && (item.step == .candidateSelection || item.step == .scanning)

                Button {
                    if item.step == .candidateSelection {
                        vm.backToCandidates()
                    } else if item.step == .scanning {
                        vm.startOver()
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isDone {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(Color.brandTeal)
                        } else {
                            Circle()
                                .fill(isActive ? Color.brandAccent : Color.secondary.opacity(0.35))
                                .frame(width: 5, height: 5)
                        }
                        Text(item.title)
                            .foregroundStyle(isActive ? Color.primary : (isDone ? Color.primary.opacity(0.75) : Color.secondary))
                            .fontWeight(isActive ? .semibold : .regular)
                    }
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background {
                        if isActive {
                            Capsule()
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.7)))
                                .matchedGeometryEffect(id: "activeStep", in: stepNamespace)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canJumpBack)
                .accessibilityLabel(L("step.a11y_fmt", item.title, idx + 1, steps.count))
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: vm.currentStep)
    }
}
