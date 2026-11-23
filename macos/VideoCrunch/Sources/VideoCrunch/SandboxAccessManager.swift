import AppKit
import Foundation

@MainActor
final class SandboxAccessManager {
    private let defaults: UserDefaults?
    private static let folderBookmarksKey = "videocrunch.folderBookmarks"
    private static let customOutputBookmarkKey = "videocrunch.customOutputFolderBookmark"

    private var activeSecurityScopedURLs: [String: URL] = [:]
    private(set) var customOutputFolderURL: URL?

    var grantedFolderCount: Int {
        (defaults?.array(forKey: Self.folderBookmarksKey) as? [Data])?.count ?? 0
    }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        startAccessingStoredBookmarks()
    }

    func startAccessingStoredBookmarks() {
        guard let defaults else { return }
        if let list = defaults.array(forKey: Self.folderBookmarksKey) as? [Data] {
            var refreshed: [Data] = []
            for data in list {
                var stale = false
                if let url = try? URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) {
                    beginAccessing(url)
                    if stale, let fresh = makeSecurityBookmark(for: url) {
                        refreshed.append(fresh)
                    } else {
                        refreshed.append(data)
                    }
                }
            }
            if refreshed.count != list.count {
                defaults.set(refreshed, forKey: Self.folderBookmarksKey)
            }
        }

        if let outData = defaults.data(forKey: Self.customOutputBookmarkKey) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: outData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                beginAccessing(url)
                customOutputFolderURL = url
                if stale, let fresh = makeSecurityBookmark(for: url) {
                    defaults.set(fresh, forKey: Self.customOutputBookmarkKey)
                }
            } else {
                defaults.removeObject(forKey: Self.customOutputBookmarkKey)
            }
        }
    }

    func stopAllAccess() {
        for url in activeSecurityScopedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
    }

    func registerGrantedFolder(_ url: URL) {
        let dir = normalizedDirectory(url)
        beginAccessing(dir)
        guard let defaults, let bookmark = makeSecurityBookmark(for: dir) else { return }
        var existing = defaults.array(forKey: Self.folderBookmarksKey) as? [Data] ?? []
        var alreadyTracked = false
        for item in existing {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: item,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), resolved.standardizedFileURL == dir {
                alreadyTracked = true
                break
            }
        }
        if !alreadyTracked {
            existing.append(bookmark)
            defaults.set(existing, forKey: Self.folderBookmarksKey)
        }
    }

    func setCustomOutputFolder(_ url: URL?) {
        guard let url else {
            customOutputFolderURL = nil
            defaults?.removeObject(forKey: Self.customOutputBookmarkKey)
            return
        }
        let dir = normalizedDirectory(url)
        beginAccessing(dir)
        customOutputFolderURL = dir
        if let defaults, let bookmark = makeSecurityBookmark(for: dir) {
            defaults.set(bookmark, forKey: Self.customOutputBookmarkKey)
        }
    }

    func clearGrantedFolders() {
        defaults?.removeObject(forKey: Self.folderBookmarksKey)
        let keepCustom = customOutputFolderURL?.standardizedFileURL
        for (key, url) in activeSecurityScopedURLs {
            if let keepCustom, url.standardizedFileURL == keepCustom { continue }
            url.stopAccessingSecurityScopedResource()
            activeSecurityScopedURLs.removeValue(forKey: key)
        }
    }

    nonisolated func canWrite(to directory: URL) -> Bool {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let probe = directory.appendingPathComponent(".vc_probe_\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .withoutOverwriting)
            try? fm.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    func ensureWriteAccess(for directories: [URL]) -> Bool {
        var seen = Set<String>()
        for rawDir in directories {
            let dir = normalizedDirectory(rawDir)
            guard seen.insert(dir.path).inserted else { continue }
            if canWrite(to: dir) { continue }

            let panel = NSOpenPanel()
            panel.title = L("sandbox.grant.title")
            panel.message = L("sandbox.grant.message_fmt", dir.lastPathComponent)
            panel.prompt = L("sandbox.grant.button")
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.directoryURL = dir

            guard panel.runModal() == .OK, let granted = panel.url else {
                return false
            }
            registerGrantedFolder(granted)
            if !canWrite(to: dir) {
                return false
            }
        }
        return true
    }

    nonisolated static func replaceOriginalWithTrash(original: URL, encoded: URL) -> URL? {
        let fm = FileManager.default
        let target = original.deletingPathExtension().appendingPathExtension("mp4")
        if target.standardizedFileURL != original.standardizedFileURL,
           fm.fileExists(atPath: target.path) {
            return nil
        }
        do {
            try fm.trashItem(at: original, resultingItemURL: nil)
            if encoded.standardizedFileURL != target.standardizedFileURL {
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
                try fm.moveItem(at: encoded, to: target)
            }
            return target
        } catch {
            return nil
        }
    }

    private func normalizedDirectory(_ url: URL) -> URL {
        url.standardizedFileURL
    }

    private func beginAccessing(_ url: URL) {
        let key = url.standardizedFileURL.path
        if activeSecurityScopedURLs[key] == nil {
            if url.startAccessingSecurityScopedResource() {
                activeSecurityScopedURLs[key] = url
            }
        }
    }

    private func makeSecurityBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}
