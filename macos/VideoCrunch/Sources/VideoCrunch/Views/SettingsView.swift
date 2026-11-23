import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var vm: WizardViewModel
    @State private var confirmResetStats = false

    private var selectedPresetBinding: Binding<String> {
        Binding(
            get: { vm.matchingPreset?.id ?? "builtin.archive" },
            set: { newId in
                if let preset = vm.allPresets.first(where: { $0.id == newId }) {
                    vm.applyPreset(preset)
                }
            }
        )
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label(L("settings.tab.general"), systemImage: "gearshape")
                }

            encodingTab
                .tabItem {
                    Label(L("settings.tab.encoding"), systemImage: "slider.horizontal.3")
                }

            privacyTab
                .tabItem {
                    Label(L("settings.tab.privacy"), systemImage: "hand.raised")
                }
        }
        .frame(width: 520, height: 350)
        .alert(L("settings.stats.reset_confirm_title"), isPresented: $confirmResetStats) {
            Button(L("action.cancel"), role: .cancel) {}
            Button(L("action.reset"), role: .destructive) {
                vm.resetLocalStats()
            }
        } message: {
            Text(L("settings.stats.reset_confirm_message"))
        }
    }

    private var generalTab: some View {
        Form {
            Section {
                Picker(L("settings.language.label"), selection: $vm.appLanguage) {
                    ForEach(AppLanguage.all) { lang in
                        Text(lang.code.isEmpty ? L("settings.language.system") : lang.displayName)
                            .tag(lang.code)
                    }
                }
                Text(L("settings.language.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(L("settings.notifications.toggle"), isOn: $vm.notificationsEnabled)
                Toggle(L("settings.haptics.toggle"), isOn: $vm.hapticsEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private var encodingTab: some View {
        Form {
            Section {
                Picker(L("settings.default_preset.label"), selection: selectedPresetBinding) {
                    ForEach(EncodePreset.builtIn) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                    if !vm.customPresets.isEmpty {
                        Divider()
                        ForEach(vm.customPresets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                }

                Button(L("settings.reset_defaults")) {
                    vm.resetSettingsToDefaults()
                }
            }

            Section(L("settings.output.title")) {
                LabeledContent(L("settings.output.title")) {
                    Text(vm.customOutputFolder?.path ?? L("settings.output.sibling"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 10) {
                    Button(L("settings.output.choose")) {
                        vm.chooseCustomOutputFolder()
                    }
                    if vm.customOutputFolder != nil {
                        Button(L("settings.output.reset")) {
                            vm.clearCustomOutputFolder()
                        }
                    }
                }

                Text(L("settings.output.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if vm.grantedFolderCount > 0 {
                    HStack {
                        Text(L("settings.output.permissions_fmt", vm.grantedFolderCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("settings.output.clear_permissions"), role: .destructive) {
                            vm.clearGrantedFolders()
                        }
                        .font(.caption)
                    }
                }
            }

            Section(L("settings.custom_presets.title")) {
                if vm.customPresets.isEmpty {
                    Text(L("settings.custom_presets.empty"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.customPresets) { preset in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .fontWeight(.medium)
                                Text("\(codecName(preset.targetCodec)) · \(QualityBalance(rawValue: preset.qualityBalance)?.label ?? preset.qualityBalance)"
                                     + (preset.scaleHeight > 0 ? " · \(preset.scaleHeight)p" : "")
                                     + (preset.sizeLimitMB > 0 ? " · ≤ \(preset.sizeLimitMB) MB" : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Spacer()
                            Button(role: .destructive) {
                                vm.deleteCustomPreset(id: preset.id)
                            } label: {
                                Image(systemName: "trash")
                                    .accessibilityLabel(L("settings.preset.delete"))
                            }
                            .buttonStyle(.borderless)
                            .help(L("settings.preset.delete"))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var privacyTab: some View {
        Form {
            Section {
                HStack {
                    Chip(text: L("settings.privacy.badge"), icon: "lock.shield", tint: .brandTeal)
                    Spacer()
                }
                Text(L("settings.privacy.body"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(L("settings.stats.title")) {
                if vm.lifetimeStats.encodedCount > 0 {
                    Text(L("scan.history.total_fmt",
                           formatBytes(vm.lifetimeStats.totalSavedBytes),
                           vm.lifetimeStats.encodedCount))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.savings)
                        .monospacedDigit()
                } else {
                    Text(L("settings.stats.empty"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button(L("settings.stats.open_logs")) {
                        let logDir = LifetimeStats.defaultHistoryURL.deletingLastPathComponent()
                        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(logDir)
                    }

                    Button(L("settings.stats.reset"), role: .destructive) {
                        confirmResetStats = true
                    }
                    .disabled(vm.lifetimeStats.encodedCount == 0 && vm.lifetimeStats.totalSavedBytes == 0)
                }
            }
        }
        .formStyle(.grouped)
    }
}
