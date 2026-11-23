import QuickLook
import SwiftUI

/// Step 2: the candidates, with what each is expected to save.
struct SelectionStep: View {
    @ObservedObject var vm: WizardViewModel

    enum CandidateFilter: String, CaseIterable {
        case all
        case recommended
        case downscaleTip

        var title: String {
            switch self {
            case .all: return L("selection.filter.all")
            case .recommended: return L("selection.filter.recommended")
            case .downscaleTip: return L("selection.filter.downscale_tip")
            }
        }
    }

    enum CandidateSort: String, CaseIterable {
        case savedMB
        case savedPct
        case size
        case name

        var title: String {
            switch self {
            case .savedMB: return L("selection.sort.saved_mb")
            case .savedPct: return L("selection.sort.saved_pct")
            case .size: return L("selection.sort.size")
            case .name: return L("selection.sort.name")
            }
        }
    }

    @State private var previewURL: URL?
    @State private var hoveredCandidate: String?
    @State private var filter: CandidateFilter = .all
    @State private var sort: CandidateSort = .savedMB

    static func visibleCandidates(
        from candidates: [Candidate],
        filter: CandidateFilter,
        sort: CandidateSort
    ) -> [Candidate] {
        let filtered: [Candidate]
        switch filter {
        case .all:
            filtered = candidates
        case .recommended:
            filtered = candidates.filter(\.isRecommended)
        case .downscaleTip:
            filtered = candidates.filter { $0.recommended_1080 == true }
        }

        return filtered.sorted { lhs, rhs in
            switch sort {
            case .savedMB:
                if lhs.estimated_saved_mb != rhs.estimated_saved_mb {
                    return lhs.estimated_saved_mb > rhs.estimated_saved_mb
                }
            case .savedPct:
                if lhs.estimated_saved_pct != rhs.estimated_saved_pct {
                    return lhs.estimated_saved_pct > rhs.estimated_saved_pct
                }
            case .size:
                if lhs.size_mb != rhs.size_mb {
                    return lhs.size_mb > rhs.size_mb
                }
            case .name:
                break
            }
            return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
        }
    }

    private var availableFilters: [CandidateFilter] {
        var list: [CandidateFilter] = [.all, .recommended]
        if vm.candidates.contains(where: { $0.recommended_1080 == true }) {
            list.append(.downscaleTip)
        }
        return list
    }

    private var visible: [Candidate] {
        Self.visibleCandidates(from: vm.candidates, filter: filter, sort: sort)
    }

    private var focusedCandidate: Candidate? {
        if let focusedId = vm.focusedCandidateId, let match = visible.first(where: { $0.id == focusedId }) {
            return match
        }
        if let firstSelected = visible.first(where: { vm.selectedIds.contains($0.id) }) {
            return firstSelected
        }
        return visible.first ?? vm.candidates.first
    }

    private func focus(_ id: String) {
        vm.focusedCandidateId = id
    }

    private func moveFocus(offset: Int) {
        guard !visible.isEmpty else { return }
        if let current = focusedCandidate,
           let idx = visible.firstIndex(where: { $0.id == current.id }) {
            let next = max(0, min(visible.count - 1, idx + offset))
            focus(visible[next].id)
        } else {
            focus(visible[0].id)
        }
    }

    /// Space previews the row under the pointer or current focus, as in Finder.
    private func previewActive() {
        guard let id = hoveredCandidate ?? focusedCandidate?.id ?? vm.candidates.first?.id else { return }
        previewURL = previewURL == nil ? URL(fileURLWithPath: id) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(L("action.preview"), action: previewActive)
                .keyboardShortcut(.space, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)

            headerBar
            Divider()

            if vm.candidates.isEmpty {
                StatusHero(icon: "checkmark.seal.fill", tint: .green,
                           title: L("selection.empty_all.title"),
                           message: L("selection.empty_all.message")) {
                    EmptyView()
                }
            } else {
                studioBody
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            moveFocus(offset: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveFocus(offset: 1)
            return .handled
        }
        .quickLookPreview($previewURL)
    }

    private var headerBar: some View {
        let totalMB = vm.candidates.reduce(0.0) { $0 + $1.size_mb }
        let potentialSavedMB = vm.candidates.reduce(0.0) { $0 + max(0, $1.estimated_saved_mb) }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.candidates.count == 1
                     ? L("selection.single_checked")
                     : L("selection.candidates_fmt", vm.candidates.count, vm.recommendedIds.count))
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(L("selection.total_fmt", formatMB(totalMB)))
                    if potentialSavedMB > 0.1 {
                        Text("·")
                        Text(L("selection.potential_fmt", formatMB(potentialSavedMB)))
                            .foregroundStyle(Color.savings)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            Spacer()

            if vm.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text(L("selection.scanning_more"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let notice = vm.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if vm.candidates.count > 1 {
                HStack(spacing: 6) {
                    Button(L("action.recommended_plural")) { vm.selectRecommended() }
                        .disabled(vm.selectedIds == vm.recommendedIds)
                        .help(L("selection.recommended_help"))
                    Button(L("action.all")) { vm.selectAll() }
                        .disabled(vm.selectedIds.count == vm.candidates.count)
                    Button(L("action.none")) { vm.deselectAll() }
                        .disabled(vm.selectedIds.isEmpty)
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: 1080)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    private var studioBody: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                if vm.candidates.count > 1 {
                    HStack(spacing: 10) {
                        Picker(L("selection.filter.all"), selection: $filter) {
                            ForEach(availableFilters, id: \.self) { f in
                                Text(f.title).tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()

                        Spacer()

                        Menu {
                            ForEach(CandidateSort.allCases, id: \.self) { option in
                                Button {
                                    sort = option
                                } label: {
                                    if sort == option {
                                        Label(option.title, systemImage: "checkmark")
                                    } else {
                                        Text(option.title)
                                    }
                                }
                            }
                        } label: {
                            Label(sort.title, systemImage: "arrow.up.arrow.down")
                        }
                        .menuStyle(.borderlessButton)
                        .controlSize(.small)
                        .fixedSize()
                    }
                }

                if visible.isEmpty {
                    VStack(spacing: 10) {
                        Text(L("selection.empty_filter_fmt", filter.title))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button(L("selection.show_all")) {
                            filter = .all
                        }
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(32)
                    .cardBackground()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(visible) { c in
                                CandidateRow(
                                    candidate: c,
                                    selected: vm.selectedIds.contains(c.id),
                                    focused: focusedCandidate?.id == c.id,
                                    toggle: {
                                        focus(c.id)
                                        vm.toggleSelection(for: c.id)
                                    },
                                    preview: {
                                        focus(c.id)
                                        previewURL = URL(fileURLWithPath: c.file_path)
                                    },
                                    inspect: {
                                        focus(c.id)
                                        vm.inspect(URL(fileURLWithPath: c.file_path))
                                    },
                                    hover: { inside in hoveredCandidate = inside ? c.id : nil }
                                )
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let c = focusedCandidate {
                ScrollView {
                    candidateInspector(for: c)
                        .padding(.bottom, 12)
                }
                .frame(width: 330)
            }
        }
        .frame(maxWidth: 1080, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func candidateInspector(for c: Candidate) -> some View {
        let afterMB = max(0, c.size_mb - c.estimated_saved_mb)
        let afterFraction = c.size_mb > 0 ? afterMB / c.size_mb : 1

        return VStack(alignment: .leading, spacing: 12) {
            VideoStagePreview(
                url: URL(fileURLWithPath: c.file_path),
                title: c.filename,
                duration: c.duration_sec,
                badge: "\(c.codec.uppercased()) · \(c.resolutionString)"
            )
            .onTapGesture {
                previewURL = URL(fileURLWithPath: c.file_path)
            }
            .help(L("selection.inspector.preview_help"))

            VStack(alignment: .leading, spacing: 10) {
                Text(L("selection.inspector.title"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    specRow(L("selection.inspector.resolution"), c.dimensionsString ?? c.resolutionString)
                    specRow(L("selection.inspector.codec"), c.codec.uppercased())
                    specRow(L("selection.inspector.bitrate"), L("unit.mbps", c.bitrate_mbps))
                    specRow(L("selection.inspector.file_size"), c.sizeFormatted)
                    if let d = c.duration_sec, d > 0 {
                        specRow(L("selection.inspector.duration"), formatDuration(d))
                    }
                }

                Divider().opacity(0.6)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L("selection.inspector.expected"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(L("selection.inspector.approx_fmt", formatMB(afterMB)))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                        Text(L("selection.inspector.saved_fmt", c.savedFormatted, Int(c.estimated_saved_pct.rounded())))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.savings)
                            .monospacedDigit()
                    }
                    CrunchMeterBar(fraction: afterFraction)
                }

                if let pct1080 = c.estimated_saved_pct_1080,
                   let mb1080 = c.estimated_saved_mb_1080 {
                    Label(L("selection.inspector.tip_1080_fmt", formatMB(mb1080), Int(pct1080.rounded())),
                          systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.brandAccent)
                        .monospacedDigit()
                }

                Text(c.advice ?? c.reasonDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.6)

                HStack(spacing: 8) {
                    Button {
                        previewURL = URL(fileURLWithPath: c.file_path)
                    } label: {
                        Label(L("action.preview"), systemImage: "eye")
                    }
                    .controlSize(.small)

                    Button {
                        vm.inspect(URL(fileURLWithPath: c.file_path))
                    } label: {
                        Label(L("action.media_info"), systemImage: "info.circle")
                    }
                    .controlSize(.small)
                }
            }
            .padding(14)
            .cardBackground()
        }
    }

    private func specRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.primary)
                .monospacedDigit()
        }
    }
}
