import AppKit
import SwiftUI
import UserNotifications

@main
struct VideoCrunchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // One window: whatever is opened — Dock, Finder, Quick Action, ⌘O,
        // a drop — goes into it instead of starting another.
        Window("VideoCrunch", id: "main") {
            WizardView(vm: appDelegate.viewModel)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        // Fits a 13" laptop with room to spare; every step fits without scrolling.
        .defaultSize(width: 980, height: 680)

        // Before/after, in a window of its own: big enough to judge detail,
        // and it can stay open next to the results.
        WindowGroup("Vergleich", for: Comparison.self) { $comparison in
            if let comparison {
                ComparisonSheet(comparison: comparison)
            }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Öffnen …") {
                    appDelegate.viewModel.chooseAndOpen()
                }
                .keyboardShortcut("o")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let viewModel = WizardViewModel()

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
        true
    }

    // A click on the "fertig" notification brings the app back; its button
    // shows the results in Finder.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let reveal = response.actionIdentifier == Notifier.revealAction
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if reveal, !self.viewModel.targetURLs.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(self.viewModel.targetURLs)
            }
            completionHandler()
        }
    }
}
