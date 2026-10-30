import AppKit
import UserNotifications

/// Progress on the Dock icon while an encode runs, so a glance is enough.
@MainActor
enum DockProgress {
    private static var view: DockProgressView?
    private static var shownPercent: Int?

    /// `fraction` 0…1 draws the bar; nil restores the plain icon.
    static func show(_ fraction: Double?) {
        let tile = NSApp.dockTile
        guard let fraction else {
            view = nil
            shownPercent = nil
            tile.contentView = nil
            tile.display()
            return
        }
        // Redrawing the tile on every output line is wasted work.
        let percent = Int((min(1, max(0, fraction)) * 100).rounded())
        guard percent != shownPercent else { return }
        shownPercent = percent
        if view == nil {
            let progressView = DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
            view = progressView
            tile.contentView = progressView
        }
        view?.fraction = Double(percent) / 100
        tile.display()
    }
}

final class DockProgressView: NSView {
    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
        // Inside the icon's tile (the icon grid leaves a ~10 % margin), white on
        // a dark track so it reads on the blue tile at Dock size.
        let track = NSRect(x: bounds.width * 0.2, y: bounds.height * 0.17,
                           width: bounds.width * 0.6, height: bounds.height * 0.09)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        let inner = track.insetBy(dx: track.height * 0.2, dy: track.height * 0.2)
        var bar = inner
        bar.size.width = max(inner.height, inner.width * fraction)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
    }
}

/// macOS notifications for a finished run, with "Im Finder zeigen".
enum Notifier {
    static let category = "videocrunch.done"
    static let revealAction = "reveal"

    static func register(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let reveal = UNNotificationAction(identifier: revealAction, title: "Im Finder zeigen")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [reveal], intentIdentifiers: [])
        ])
    }

    /// Only when the app is in the background: in front, the Fertig page
    /// already says it. Falls back to AppleScript when notifications are not
    /// allowed for the app.
    @MainActor
    static func notify(title: String, body: String) {
        guard !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                scriptNotification(title: title, body: body)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = category
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            ) { error in
                if error != nil {
                    scriptNotification(title: title, body: body)
                }
            }
        }
    }

    private static func scriptNotification(title: String, body: String) {
        let quote = { (text: String) in text.replacingOccurrences(of: "\"", with: "'") }
        let script = "display notification \"\(quote(body))\" with title \"\(quote(title))\" sound name \"Glass\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }
}

/// "ca. 3 Min", "unter 1 Min", "ca. 1 Std 10 Min".
func formatDuration(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    if minutes < 1 { return "unter 1 Min" }
    if minutes < 60 { return "ca. \(minutes) Min" }
    let rest = minutes % 60
    return rest == 0 ? "ca. \(minutes / 60) Std" : "ca. \(minutes / 60) Std \(rest) Min"
}
