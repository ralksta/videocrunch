import SwiftUI
import AppKit

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
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = WizardViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
}
