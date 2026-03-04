import Foundation
import AppKit

/// JetBrains PyCharm integration
/// Also serves as a template for other JetBrains IDEs (IntelliJ, WebStorm, etc.)
public struct PyCharmIntegration: TerminalIntegration {
    public static let identifier = "PyCharm"
    public static let displayName = "PyCharm"

    /// Port used by the Beacon Terminal Navigator JetBrains plugin
    static let pluginPort = 19877

    private static func log(_ message: String) {
        let logPath = "/tmp/beacon_debug.log"
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [PyCharm] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            }
        }
    }

    public static func matches(processInfo: ProcessInfo) -> Bool {
        let name = processInfo.terminalName.lowercased()
        return name.contains("pycharm")
    }

    public static func extractMetadata(processInfo: ProcessInfo) -> [String: String] {
        var metadata: [String: String] = [:]

        // Query the plugin for project/tab info matching this working directory
        if let pluginInfo = queryPluginForProject(workingDirectory: processInfo.workingDirectory) {
            metadata["pycharmWindow"] = pluginInfo.project
            metadata["pycharmTabName"] = pluginInfo.tabName
            metadata["pycharmBasePath"] = pluginInfo.basePath
            log("extractMetadata: plugin returned project=\(pluginInfo.project), basePath=\(pluginInfo.basePath), tab=\(pluginInfo.tabName)")
            return metadata
        }

        // Fallback: Try to capture the current frontmost PyCharm window name
        if let windowName = getFrontmostWindowName() {
            metadata["pycharmWindow"] = windowName
            log("extractMetadata: fallback to frontmost window=\(windowName)")
        }

        return metadata
    }

    public static func activate(session: SessionContext) {
        let tabName = session.metadata["pycharmTabName"]
        let windowName = session.metadata["pycharmWindow"]
        log("activate: project=\(session.projectName), tabName=\(tabName ?? "nil"), window=\(windowName ?? "nil"), cwd=\(session.workingDirectory)")

        let targetWindow = windowName ?? session.projectName

        // Resolve which tab to focus (stored from hook or dynamic query)
        var focusProject: String?
        var focusTab: String?
        var focusBasePath: String?

        if let tabName = tabName, !tabName.isEmpty {
            focusProject = windowName ?? session.projectName
            focusTab = tabName
            focusBasePath = session.metadata["pycharmBasePath"]
        } else if let pluginInfo = queryPluginForProject(workingDirectory: session.workingDirectory) {
            log("dynamic plugin query found project=\(pluginInfo.project), tab=\(pluginInfo.tabName)")
            focusProject = pluginInfo.project
            focusTab = pluginInfo.tabName
            focusBasePath = pluginInfo.basePath
        }

        // Step 1: Try plugin-based focus first (plugin knows exact project by basePath).
        // This avoids AppleScript raising the wrong window when multiple projects
        // share similar names (e.g., ~/repo/proxysql vs ~/repo/soda-k8s/charts/proxysql).
        if let project = focusProject, let tab = focusTab {
            activateJetBrainsApp()
            if focusViaPlugin(project: project, tabName: tab, basePath: focusBasePath ?? session.workingDirectory, retryOnFailure: true) {
                log("plugin focused tab '\(tab)' in project '\(project)' — done")
                return
            }
            log("plugin focus failed, falling back to AppleScript")
        }

        // Step 2: Fallback — use AppleScript to raise window by basePath or name
        activateJetBrainsApp()
        let basePath = focusBasePath ?? session.metadata["pycharmBasePath"]
        if let basePath = basePath, !basePath.isEmpty {
            raiseWindowByBasePath(basePath)
        } else if let windowName = windowName, !windowName.isEmpty {
            raiseWindow(named: windowName)
        } else {
            raiseWindowByProjectName(session.projectName, workingDirectory: session.workingDirectory)
        }

        // Step 3: Try plugin one more time with basePath only
        if focusViaPlugin(project: targetWindow, tabName: nil, basePath: session.workingDirectory, retryOnFailure: false) {
            log("plugin focused project window only (no tab) — done")
            return
        }

        log("activate: all plugin strategies failed, window already raised via AppleScript")
    }

    // MARK: - Plugin API

    /// Information returned by the plugin for a project
    struct PluginProjectInfo {
        let project: String
        let basePath: String
        let tabName: String
        let allTabs: [String]
    }

    /// Query the plugin for project/tab info matching a working directory
    static func queryPluginForProject(workingDirectory: String) -> PluginProjectInfo? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = [
            "-s",
            "--connect-timeout", "1",
            "--max-time", "2",
            "http://127.0.0.1:\(pluginPort)/active-terminal"
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard task.terminationStatus == 0,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return nil
            }

            // Find project whose basePath best matches the working directory.
            // Prefer the most specific (longest basePath) match to avoid
            // confusing ~/repo/proxysql with ~/repo/soda-k8s/charts/proxysql.
            var bestMatch: PluginProjectInfo?
            var bestMatchLength = -1

            for entry in json {
                guard let basePath = entry["basePath"] as? String,
                      let project = entry["project"] as? String,
                      let tabName = entry["tabName"] as? String else { continue }

                let allTabs = entry["tabs"] as? [String] ?? []

                if workingDirectory == basePath {
                    // Exact match — return immediately
                    return PluginProjectInfo(project: project, basePath: basePath, tabName: tabName, allTabs: allTabs)
                }

                if workingDirectory.hasPrefix(basePath + "/") && basePath.count > bestMatchLength {
                    bestMatch = PluginProjectInfo(project: project, basePath: basePath, tabName: tabName, allTabs: allTabs)
                    bestMatchLength = basePath.count
                } else if basePath.hasPrefix(workingDirectory + "/") && bestMatch == nil {
                    bestMatch = PluginProjectInfo(project: project, basePath: basePath, tabName: tabName, allTabs: allTabs)
                }
            }
            return bestMatch
        } catch {
            log("queryPluginForProject error: \(error)")
            return nil
        }
    }

    /// Focus a terminal tab via the Beacon Terminal Navigator JetBrains plugin.
    /// The plugin now also brings the IDE window to front.
    /// Returns true if the plugin responded successfully.
    private static func focusViaPlugin(project: String, tabName: String?, basePath: String?, retryOnFailure: Bool = true) -> Bool {
        // Build JSON payload
        var fields: [String] = []
        fields.append("\"project\":\"\(escapeJsonString(project))\"")
        if let tabName = tabName, !tabName.isEmpty {
            fields.append("\"tabName\":\"\(escapeJsonString(tabName))\"")
        }
        if let basePath = basePath, !basePath.isEmpty {
            fields.append("\"basePath\":\"\(escapeJsonString(basePath))\"")
        }
        let payload = "{\(fields.joined(separator: ","))}"

        let success = sendPluginRequest(endpoint: "focus-terminal", payload: payload, maxTime: "3")

        if !success && retryOnFailure {
            log("focusViaPlugin: first attempt failed, retrying with longer timeout...")
            Thread.sleep(forTimeInterval: 0.5)
            return sendPluginRequest(endpoint: "focus-terminal", payload: payload, maxTime: "5")
        }

        return success
    }

    /// Send an HTTP POST request to the JetBrains plugin
    private static func sendPluginRequest(endpoint: String, payload: String, maxTime: String = "3") -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = [
            "-s", "-o", "/dev/null", "-w", "%{http_code}",
            "--connect-timeout", "2",
            "--max-time", maxTime,
            "-X", "POST",
            "http://127.0.0.1:\(pluginPort)/\(endpoint)",
            "-H", "Content-Type: application/json",
            "-d", payload
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let httpCode = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            log("sendPluginRequest /\(endpoint) HTTP \(httpCode) (payload: \(payload))")
            return httpCode == "200"
        } catch {
            log("sendPluginRequest /\(endpoint) error: \(error)")
            return false
        }
    }

    /// Check if the Beacon JetBrains plugin is reachable.
    public static func isPluginAvailable() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = [
            "-s", "-o", "/dev/null", "-w", "%{http_code}",
            "--connect-timeout", "1",
            "--max-time", "1",
            "http://127.0.0.1:\(pluginPort)/health"
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let httpCode = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return httpCode == "200"
        } catch {
            return false
        }
    }

    // MARK: - Plugin Installation

    /// Check if the Beacon JetBrains plugin is installed on disk (regardless of whether IDE is running)
    public static func isPluginInstalled() -> Bool {
        let jbPath = NSHomeDirectory() + "/Library/Application Support/JetBrains"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: jbPath) else {
            return false
        }
        // Check all PyCharm version directories for the plugin
        for dir in contents where dir.hasPrefix("PyCharm") {
            let pluginDir = jbPath + "/\(dir)/plugins/beacon-terminal-navigator"
            if FileManager.default.fileExists(atPath: pluginDir) {
                return true
            }
        }
        return false
    }

    /// Install the Beacon plugin into the latest PyCharm plugins directory.
    /// Returns (success, errorMessage)
    public static func installPlugin() -> (Bool, String?) {
        // Find the plugin zip
        let zipPaths = [
            Bundle.main.resourcePath.map { $0 + "/beacon-terminal-navigator-1.0.0.zip" },
            Bundle.main.bundlePath + "/Contents/Resources/beacon-terminal-navigator-1.0.0.zip",
        ].compactMap { $0 }

        let repoZipPath = (Bundle.main.bundlePath as NSString)
            .deletingLastPathComponent + "/plugins/beacon-terminal-navigator/build/distributions/beacon-terminal-navigator-1.0.0.zip"

        let allPaths = zipPaths + [repoZipPath]

        var zipPath: String?
        for path in allPaths {
            if FileManager.default.fileExists(atPath: path) {
                zipPath = path
                break
            }
        }

        guard let foundZip = zipPath else {
            return (false, "Plugin zip not found")
        }

        // Find the latest PyCharm version directory
        let jbPath = NSHomeDirectory() + "/Library/Application Support/JetBrains"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: jbPath) else {
            return (false, "JetBrains config directory not found")
        }

        let pycharmDirs = contents.filter { $0.hasPrefix("PyCharm") }.sorted().reversed()
        guard let latestPyCharm = pycharmDirs.first else {
            return (false, "No PyCharm installation found")
        }

        let pluginsDir = jbPath + "/\(latestPyCharm)/plugins"
        let targetDir = pluginsDir + "/beacon-terminal-navigator"

        // Create plugins dir if needed
        try? FileManager.default.createDirectory(atPath: pluginsDir, withIntermediateDirectories: true)

        // Unzip the plugin
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-o", foundZip, "-d", pluginsDir]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if task.terminationStatus == 0 && FileManager.default.fileExists(atPath: targetDir) {
                log("installPlugin: success — installed to \(targetDir)")
                return (true, nil)
            } else {
                log("installPlugin: failed — \(output)")
                return (false, output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch {
            log("installPlugin: error — \(error)")
            return (false, error.localizedDescription)
        }
    }

    // MARK: - App Activation

    /// Activate the JetBrains IDE app at OS level.
    /// Dynamically detects the correct app name from running processes.
    private static func activateJetBrainsApp() {
        // Find any running JetBrains app (PyCharm, IntelliJ, etc.)
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            let name = app.localizedName ?? ""
            let bundleId = app.bundleIdentifier ?? ""
            if name.lowercased().contains("pycharm") || bundleId.lowercased().contains("pycharm") {
                log("activateJetBrainsApp: activating '\(name)' (bundle: \(bundleId))")
                app.activate()
                return
            }
        }
        // Broader JetBrains match
        for app in runningApps {
            let bundleId = app.bundleIdentifier ?? ""
            if bundleId.contains("jetbrains") {
                log("activateJetBrainsApp: activating JetBrains app '\(app.localizedName ?? "")' (bundle: \(bundleId))")
                app.activate()
                return
            }
        }
        // Last resort: AppleScript
        log("activateJetBrainsApp: no running app found, trying AppleScript")
        activateApp("PyCharm")
    }

    // MARK: - Window-Level Navigation (AppleScript fallback)

    /// Raise a specific PyCharm window by name via osascript subprocess.
    /// Uses Process instead of NSAppleScript for reliable AXRaise in LaunchAgent context.
    private static func raiseWindow(named windowProject: String) {
        guard let processName = getJetBrainsProcessName() else {
            log("raiseWindow: could not find JetBrains process name")
            return
        }
        let script = """
            tell application "System Events"
                tell process "\(processName)"
                    repeat with w in windows
                        if name of w contains "\(escapeAppleScript(windowProject))" then
                            perform action "AXRaise" of w
                            return "raised"
                        end if
                    end repeat
                end tell
            end tell
            return "not found"
            """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            log("raiseWindow(\(windowProject)): \(result)")
        } catch {
            log("raiseWindow(\(windowProject)) error: \(error)")
        }
    }

    /// Raise a PyCharm window using the full basePath for disambiguation.
    /// PyCharm window titles often include the path when projects share the same name,
    /// e.g., "proxysql [~/repo/proxysql]" vs "proxysql [~/repo/soda-k8s/charts/proxysql]".
    /// Falls back to matching the last path component of basePath against window titles.
    private static func raiseWindowByBasePath(_ basePath: String) {
        guard let processName = getJetBrainsProcessName() else {
            log("raiseWindowByBasePath: could not find JetBrains process name")
            return
        }

        // Try matching with full basePath first, then last component
        let lastComponent = URL(fileURLWithPath: basePath).lastPathComponent
        // Also try parent/name combo for disambiguation (e.g., "charts/proxysql")
        let parentAndName: String = {
            let url = URL(fileURLWithPath: basePath)
            let parent = url.deletingLastPathComponent().lastPathComponent
            return parent.isEmpty ? lastComponent : "\(parent)/\(lastComponent)"
        }()
        let searchTerms = [basePath, parentAndName, lastComponent]

        for term in searchTerms {
            let script = """
                tell application "System Events"
                    tell process "\(processName)"
                        repeat with w in windows
                            set wName to name of w as text
                            if wName contains "\(escapeAppleScript(term))" then
                                perform action "AXRaise" of w
                                return "found"
                            end if
                        end repeat
                    end tell
                end tell
                return "not found"
                """
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if result == "found" {
                    log("raiseWindowByBasePath: matched window with term '\(term)'")
                    return
                }
            } catch {
                log("raiseWindowByBasePath: osascript error for '\(term)': \(error)")
            }
        }
        log("raiseWindowByBasePath: no window found for basePath '\(basePath)'")
    }

    private static func raiseWindowByProjectName(_ projectName: String, workingDirectory: String) {
        var searchTerms = projectName.components(separatedBy: ":")
        searchTerms += projectName.components(separatedBy: "/")
        searchTerms.append(URL(fileURLWithPath: workingDirectory).lastPathComponent)
        searchTerms = Array(Set(searchTerms.filter { !$0.isEmpty }))

        guard let processName = getJetBrainsProcessName() else {
            log("raiseWindowByProjectName: could not find JetBrains process name")
            return
        }

        for term in searchTerms {
            let script = """
                tell application "System Events"
                    tell process "\(processName)"
                        repeat with w in windows
                            set wName to name of w as text
                            if wName contains "\(escapeAppleScript(term))" then
                                perform action "AXRaise" of w
                                return "found"
                            end if
                        end repeat
                    end tell
                end tell
                return "not found"
                """
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if result == "found" {
                    log("raiseWindowByProjectName: found window matching '\(term)'")
                    return
                }
            } catch {
                log("raiseWindowByProjectName: osascript error for '\(term)': \(error)")
            }
        }
        log("raiseWindowByProjectName: no window found for any search term")
    }

    /// Get the actual process name of the running JetBrains IDE as seen by System Events
    private static func getJetBrainsProcessName() -> String? {
        let script = """
            tell application "System Events"
                set processList to name of every process
                repeat with procName in processList
                    if procName contains "pycharm" or procName contains "PyCharm" then
                        return procName as text
                    end if
                end repeat
                -- Broader JetBrains match
                repeat with procName in processList
                    if procName contains "jetbrains" or procName contains "JetBrains" then
                        return procName as text
                    end if
                end repeat
            end tell
            return ""
            """
        if let result = runAppleScript(script)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !result.isEmpty {
            log("getJetBrainsProcessName: found '\(result)'")
            return result
        }
        // Hardcoded fallback
        return "pycharm"
    }

    private static func getFrontmostWindowName() -> String? {
        guard let processName = getJetBrainsProcessName() else { return nil }
        let script = """
            tell application "System Events"
                tell process "\(processName)"
                    set frontWindowName to name of front window
                    return frontWindowName
                end tell
            end tell
            """
        return runAppleScript(script)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func escapeJsonString(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func escapeAppleScript(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
