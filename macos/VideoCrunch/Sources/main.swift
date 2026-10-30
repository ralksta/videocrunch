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
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
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
