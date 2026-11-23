import Foundation

enum AppRuntime {
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static func resolveScriptDir(
        bundle: Bundle = .main,
        fallbackCwd: String = FileManager.default.currentDirectoryPath
    ) -> URL {
        if let res = bundle.resourceURL {
            let engine = res.appendingPathComponent("Engine", isDirectory: true)
            if FileManager.default.fileExists(atPath: engine.appendingPathComponent("scan.py").path) {
                return engine
            }
        }
        if let repo = bundle.object(forInfoDictionaryKey: "VideoCrunchRepoPath") as? String {
            return URL(fileURLWithPath: repo)
        }
        return URL(fileURLWithPath: fallbackCwd)
    }

    static func bundledHelpersDir(bundle: Bundle = .main) -> URL? {
        let dir = bundle.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
            return dir
        }
        return nil
    }

    static func bundledPythonExecutableURL(bundle: Bundle = .main) -> URL? {
        guard let helpers = bundledHelpersDir(bundle: bundle) else { return nil }
        let py = helpers.appendingPathComponent("python3")
        return FileManager.default.isExecutableFile(atPath: py.path) ? py : nil
    }

    static func bundledPythonHome(bundle: Bundle = .main) -> URL? {
        guard let home = bundle.resourceURL?.appendingPathComponent("Python", isDirectory: true) else {
            return nil
        }
        let lib = home.appendingPathComponent("lib", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: lib.path, isDirectory: &isDir), isDir.boolValue {
            return home
        }
        return nil
    }

    static func resolvePythonPath(
        scriptDir: URL,
        bundle: Bundle = .main,
        env: [String: String]? = nil
    ) -> String {
        if let bundledPy = bundledPythonExecutableURL(bundle: bundle) {
            return bundledPy.path
        }
        let venvPython = scriptDir.appendingPathComponent(".venv/bin/python3").path
        if FileManager.default.isExecutableFile(atPath: venvPython) {
            return venvPython
        }
        let activeEnv = env ?? toolEnvironment(bundle: bundle)
        let path = activeEnv["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/python3"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "/usr/bin/python3"
    }

    static func executableURL(
        for tool: String,
        bundle: Bundle = .main,
        env: [String: String]? = nil
    ) -> URL? {
        if let helpers = bundledHelpersDir(bundle: bundle) {
            let bundled = helpers.appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }
        let activeEnv = env ?? toolEnvironment(bundle: bundle)
        let path = activeEnv["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: "\(dir)/\(tool)")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func logDirectoryURL(
        sandboxed: Bool = isSandboxed,
        fileManager: FileManager = .default
    ) -> URL {
        if sandboxed,
           let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport
                .appendingPathComponent("VideoCrunch", isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".videocrunch", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    static func toolEnvironment(
        bundle: Bundle = .main,
        sandboxed: Bool = isSandboxed,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        var pathEntries: [String] = []
        if let helpers = bundledHelpersDir(bundle: bundle) {
            pathEntries.append(helpers.path)
        }
        if let pyHome = bundledPythonHome(bundle: bundle) {
            env["PYTHONHOME"] = pyHome.path
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            env["PYTHONNOUSERSITE"] = "1"
            env["PYTHONUTF8"] = "1"
        }
        if !sandboxed {
            for devDir in ["/opt/homebrew/bin", "/usr/local/bin"] where !pathEntries.contains(devDir) {
                pathEntries.append(devDir)
            }
        }
        let current = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)
        let filteredCurrent = sandboxed
            ? current.filter { $0 != "/opt/homebrew/bin" && $0 != "/usr/local/bin" }
            : current
        for entry in filteredCurrent where !pathEntries.contains(entry) {
            pathEntries.append(entry)
        }
        env["PATH"] = pathEntries.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["VIDEOCRUNCH_LOG_DIR"] = logDirectoryURL(sandboxed: sandboxed).path
        return env
    }

    static func licensesDirectoryURL(bundle: Bundle = .main) -> URL? {
        guard let dir = bundle.resourceURL?.appendingPathComponent("LICENSES", isDirectory: true) else {
            return nil
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
            return dir
        }
        return nil
    }
}
