import AppKit
import SwiftUI
import UserNotifications

@main
struct VideoCrunchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // One window: whatever is opened — Dock, Finder, Quick Action, ⌘O,
        // a drop — goes into it instead of starting another.
        Window(L("app.name"), id: "main") {
            WizardView(vm: appDelegate.viewModel)
                .tint(Color.brandAccent)
                .id(appDelegate.viewModel.appLanguage)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        // Fits a 13" laptop with room to spare; every step fits without scrolling.
        .defaultSize(width: 980, height: 680)
        .commands {
            VideoCrunchCommands(vm: appDelegate.viewModel)
        }

        // Before/after, in a window of its own: big enough to judge detail,
        // and it can stay open next to the results.
        WindowGroup(L("comparison.window_title"), for: Comparison.self) { $comparison in
            if let comparison {
                ComparisonSheet(comparison: comparison)
                    .tint(Color.brandAccent)
                    .id(appDelegate.viewModel.appLanguage)
            }
        }
        .windowResizability(.contentMinSize)

        Window(L("menu.about"), id: "about") {
            AboutView()
                .tint(Color.brandAccent)
                .id(appDelegate.viewModel.appLanguage)
        }
        .windowResizability(.contentSize)

        Window(L("shortcuts.title"), id: "shortcuts") {
            KeyboardShortcutsView()
                .tint(Color.brandAccent)
                .id(appDelegate.viewModel.appLanguage)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(vm: appDelegate.viewModel)
                .tint(Color.brandAccent)
                .id(appDelegate.viewModel.appLanguage)
        }
    }
}

private struct VideoCrunchCommands: Commands {
    @ObservedObject var vm: WizardViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L("menu.about")) {
                openWindow(id: "about")
            }
        }

        CommandGroup(replacing: .newItem) {
            Button(L("action.open_ellipsis")) {
                vm.chooseAndOpen()
            }
            .keyboardShortcut("o")

            Button(L("menu.start_over")) {
                vm.startOver()
            }
            .keyboardShortcut("n")
            .disabled(vm.currentStep == .scanning || vm.isEncoding)

            Divider()

            Button(L("action.reveal_in_finder")) {
                vm.revealCurrentInFinder()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(vm.revealableURLs.isEmpty)
        }

        CommandGroup(after: .pasteboard) {
            Divider()

            Button(L("menu.select_all")) {
                vm.selectAll()
            }
            .keyboardShortcut("a")
            .disabled(vm.currentStep != .candidateSelection || vm.candidates.isEmpty)

            Button(L("menu.select_recommended")) {
                vm.selectRecommended()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(vm.currentStep != .candidateSelection || vm.candidates.isEmpty)

            Button(L("menu.deselect_all")) {
                vm.deselectAll()
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(vm.currentStep != .candidateSelection || vm.selectedIds.isEmpty)
        }

        CommandMenu(L("menu.video")) {
            Button(L("action.media_info")) {
                vm.inspectPrimary()
            }
            .keyboardShortcut("i")
            .disabled(vm.primaryInspectableURL == nil)

            Button(L("menu.start_encode")) {
                vm.startEncoding()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(vm.currentStep != .options || vm.selectedIds.isEmpty)

            Button(L("menu.cancel_encode")) {
                vm.cancelEncoding()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!vm.isEncoding)

            Divider()

            Button(L("action.back")) {
                vm.goBack()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!vm.canGoBack)
        }

        CommandGroup(replacing: .help) {
            Button(L("menu.keyboard_shortcuts")) {
                openWindow(id: "shortcuts")
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let viewModel = WizardViewModel(defaults: .standard)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.register(delegate: self)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Started with paths as arguments (a terminal, the binary directly).
        // "-Key value" pairs are AppKit defaults (e.g. -NSRequiresAquaSystemAppearance
        // YES), not files: the flag and its value are both skipped.
        var paths: [String] = []
        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            if argument.hasPrefix("-") {
                _ = arguments.next()
            } else {
                paths.append(argument)
            }
        }
        if !paths.isEmpty {
            viewModel.open(paths.map { URL(fileURLWithPath: $0) })
        }
    }

    // Files dropped on the Dock icon, "Öffnen mit", the Quick Action (open -a).
    func application(_ application: NSApplication, open urls: [URL]) {
        viewModel.open(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !viewModel.isEncoding
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard viewModel.isEncoding else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("quit.title")
        alert.informativeText = L("quit.message")
        alert.addButton(withTitle: L("quit.keep_running"))
        let quitButton = alert.addButton(withTitle: L("quit.cancel_and_quit"))
        quitButton.hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn {
            viewModel.cancelEncoding()
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.sandboxAccess.stopAllAccess()
    }

    // A click on the "fertig" notification brings the app back; its button
    // shows the results in Finder.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let reveal = response.actionIdentifier == Notifier.revealAction
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if reveal {
                self.viewModel.revealCurrentInFinder()
            }
            completionHandler()
        }
    }
}
