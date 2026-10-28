import SwiftUI
import AppKit

@main
struct VideoCrunchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = WizardViewModel()

    var body: some Scene {
        WindowGroup {
            WizardView(vm: viewModel)
                .onAppear {
                    // Check command line arguments passed to the app
                    let args = CommandLine.arguments
                    if args.count > 1 {
                        let path = args[1]
                        let url = URL(fileURLWithPath: path)
                        viewModel.startScan(for: url)
                    }
                    appDelegate.viewModel = viewModel
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var viewModel: WizardViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Handle files dropped on app or opened via "Open With" / Services
    func application(_ application: NSApplication, openFiles filenames: [String]) {
        guard let first = filenames.first else { return }
        let url = URL(fileURLWithPath: first)
        DispatchQueue.main.async {
            self.viewModel?.startScan(for: url)
        }
    }
}
