import AppKit
import SwiftUI

struct AboutView: View {
    @State private var showLicenses = false

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return L("about.version_fmt", short, build)
    }

    var body: some View {
        VStack(spacing: 14) {
            if let icon = NSApp?.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 76, height: 76)
                    .accessibilityHidden(true)
            } else {
                CrunchMark(size: 64, squeeze: 0.25)
            }

            VStack(spacing: 4) {
                Text(L("app.name"))
                    .font(.title2.weight(.bold))
                Text(versionString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(L("about.tagline"))
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Chip(text: L("about.free_local"), icon: "lock.shield", tint: .brandTeal)

            Divider()

            Text(L("about.license_note"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Button(L("about.licenses_button")) {
                showLicenses = true
            }
            .controlSize(.small)
        }
        .padding(24)
        .frame(width: 390)
        .background(NotRestorable())
        .sheet(isPresented: $showLicenses) {
            LicensesSheetView()
        }
    }
}

private struct LicensesSheetView: View {
    @Environment(\.dismiss) private var dismiss

    private var noticesText: String {
        if let dir = AppRuntime.licensesDirectoryURL() {
            let noticesURL = dir.appendingPathComponent("NOTICES.txt")
            if let text = try? String(contentsOf: noticesURL, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return L("about.licenses_fallback")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("about.licenses_title"))
                    .font(.headline)
                Spacer()
                Button(L("action.close")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                Text(noticesText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(width: 620, height: 460)
    }
}

struct KeyboardShortcutsView: View {
    private struct ShortcutItem: Identifiable {
        let keys: String
        let title: String
        var id: String { "\(keys)-\(title)" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                shortcutSection(
                    title: L("shortcuts.section.general"),
                    items: [
                        ShortcutItem(keys: "⌘ O", title: L("shortcuts.choose_files")),
                        ShortcutItem(keys: "⌘ I", title: L("shortcuts.media_info")),
                        ShortcutItem(keys: "⌘ ,", title: L("shortcuts.settings")),
                        ShortcutItem(keys: "⌘ N", title: L("shortcuts.start_over")),
                        ShortcutItem(keys: "⌘ [", title: L("shortcuts.back")),
                    ]
                )

                shortcutSection(
                    title: L("shortcuts.section.selection"),
                    items: [
                        ShortcutItem(keys: "Space", title: L("shortcuts.quicklook")),
                        ShortcutItem(keys: "↑ / ↓", title: L("shortcuts.arrow_nav")),
                        ShortcutItem(keys: "⌘ A", title: L("shortcuts.select_all")),
                        ShortcutItem(keys: "⇧ ⌘ A", title: L("shortcuts.select_recommended")),
                        ShortcutItem(keys: "⌥ ⌘ A", title: L("shortcuts.deselect_all")),
                    ]
                )

                shortcutSection(
                    title: L("shortcuts.section.trimming"),
                    items: [
                        ShortcutItem(keys: "← / →", title: L("shortcuts.frame_step")),
                        ShortcutItem(keys: "⇧ ← / ⇧ →", title: L("shortcuts.second_step")),
                        ShortcutItem(keys: "I", title: L("shortcuts.set_in")),
                        ShortcutItem(keys: "O", title: L("shortcuts.set_out")),
                    ]
                )

                shortcutSection(
                    title: L("shortcuts.section.encoding"),
                    items: [
                        ShortcutItem(keys: "⌘ ↩", title: L("shortcuts.start_encode")),
                        ShortcutItem(keys: "⌘ .", title: L("shortcuts.cancel_encode")),
                        ShortcutItem(keys: "⇧ ⌘ R", title: L("shortcuts.reveal")),
                    ]
                )
            }
            .padding(22)
        }
        .frame(width: 460, height: 500)
        .background(NotRestorable())
    }

    private func shortcutSection(title: String, items: [ShortcutItem]) -> some View {
        OptionSection(title: title) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 { Divider().padding(.leading, 12) }
                    HStack(spacing: 12) {
                        Text(item.title)
                            .font(.callout)
                        Spacer()
                        Text(item.keys)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.75))
                            )
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .cardBackground()
        }
    }
}
