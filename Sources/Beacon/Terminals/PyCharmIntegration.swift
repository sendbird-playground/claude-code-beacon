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
            log("extractMetadata: plugin returned project=\(pluginInfo.project), tab=\(pluginInfo.tabName)")
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

        // Strategy 1: Use the JetBrains plugin API (handles both tab switching AND window activation)
        if let tabName = tabName, !tabName.isEmpty {
            let windowProject = windowName ?? session.projectName
            if focusViaPlugin(project: windowProject, tabName: tabName, basePath: nil) {
                log("plugin focused tab '\(tabName)' in project '\(windowProject)' — done")
                activateJetBrainsApp()
                // Raise the specific project window (app.activate only brings last-active window)
                raiseWindow(named: windowProject)
                return
            }
            log("plugin failed with stored tab info, trying basePath match...")
        }

        log("activate: strategy 1 (stored tab) failed or skipped")

        // Strategy 2: No stored tabName (running session) — dynamically query plugin by working directory
        if let pluginInfo = queryPluginForProject(workingDirectory: session.workingDirectory) {
            log("dynamic plugin query found project=\(pluginInfo.project), tab=\(pluginInfo.tabName)")
            if focusViaPlugin(project: pluginInfo.project, tabName: pluginInfo.tabName, basePath: pluginInfo.basePath) {
                log("plugin focused via dynamic query — done")
                activateJetBrainsApp()
                raiseWindow(named: pluginInfo.project)
                return
            }
        }

        log("activate: strategy 2 (dynamic query) failed or not available")

        // Strategy 3: Plugin unavailable — use basePath to focus without tab info
        if focusViaPlugin(project: windowName ?? session.projectName, tabName: nil, basePath: session.workingDirectory) {
            log("plugin focused project window only (no tab) — done")
            activateJetBrainsApp()
            raiseWindow(named: windowName ?? session.projectName)
            return
        }

        log("activate: strategy 3 (project-only) failed")
        log("plugin not available or all strategies failed, falling back to AppleScript")

        // Strategy 4: Fall back to AppleScript window-level navigation (no tab switching)
        activateJetBrainsApp()
        if let windowName = windowName, !windowName.isEmpty {
            raiseWindow(named: windowName)
        } else {
            raiseWindowByProjectName(session.projectName, workingDirectory: session.workingDirectory)
        }
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

            // Find project whose basePath matches the working directory
            for entry in json {
                guard let basePath = entry["basePath"] as? String,
                      let project = entry["project"] as? String,
                      let tabName = entry["tabName"] as? String else { continue }

                if workingDirectory == basePath || workingDirectory.hasPrefix(basePath + "/") || basePath.hasPrefix(workingDirectory + "/") {
                    let allTabs = entry["tabs"] as? [String] ?? []
                    return PluginProjectInfo(project: project, basePath: basePath, tabName: tabName, allTabs: allTabs)
                }
            }
            return nil
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
