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

        // Try to capture the current frontmost PyCharm window name
        if let windowName = getFrontmostWindowName() {
            metadata["pycharmWindow"] = windowName
        }

        return metadata
    }

    public static func activate(session: SessionContext) {
        let tabName = session.metadata["pycharmTabName"]
        let windowName = session.metadata["pycharmWindow"]
        log("activate: project=\(session.projectName), tabName=\(tabName ?? "nil"), window=\(windowName ?? "nil")")

        // Best path: use the JetBrains plugin API to focus the terminal tab
        if let tabName = tabName, !tabName.isEmpty {
            let windowProject = windowName ?? session.projectName
            if focusViaPlugin(project: windowProject, tabName: tabName) {
                log("plugin focused tab '\(tabName)' in project '\(windowProject)'")
                activateApp("PyCharm")
                raiseWindow(named: windowProject)
                return
            }
            log("plugin not available or failed, falling back to window-level navigation")
        }

        // Fall back to window-level navigation (no tab switching)
        if let windowName = windowName, !windowName.isEmpty {
            activateByWindowName(windowName)
        } else {
            activateByProjectName(session.projectName, workingDirectory: session.workingDirectory)
        }
    }

    // MARK: - Plugin API

    /// Focus a terminal tab via the Beacon Terminal Navigator JetBrains plugin.
    /// Returns true if the plugin responded successfully.
    private static func focusViaPlugin(project: String, tabName: String) -> Bool {
        let payload = "{\"project\":\"\(project)\",\"tabName\":\"\(tabName)\"}"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = [
            "-s", "-o", "/dev/null", "-w", "%{http_code}",
            "--connect-timeout", "1",
            "--max-time", "2",
            "-X", "POST",
            "http://127.0.0.1:\(pluginPort)/focus-terminal",
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
            log("focusViaPlugin HTTP \(httpCode)")
            return httpCode == "200"
        } catch {
            log("focusViaPlugin error: \(error)")
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

    // MARK: - Window-Level Navigation

    /// Raise a specific PyCharm window by name via osascript
    private static func raiseWindow(named windowProject: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", """
            tell application "System Events"
                tell process "pycharm"
                    repeat with w in windows
                        if name of w contains "\(windowProject)" then
                            perform action "AXRaise" of w
                            return "raised"
                        end if
                    end repeat
                end tell
            end tell
            return "not found"
            """]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {}
    }

    private static func getFrontmostWindowName() -> String? {
        let script = """
            tell application "System Events"
                tell process "pycharm"
                    set frontWindowName to name of front window
                    return frontWindowName
                end tell
            end tell
            """
        return runAppleScript(script)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func activateByWindowName(_ windowName: String) {
        log("activating by window name '\(windowName)'")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", """
            tell application "System Events"
                tell process "pycharm"
                    repeat with w in windows
                        set wName to name of w as text
                        if wName contains "\(windowName)" then
                            tell application "PyCharm" to activate
                            perform action "AXRaise" of w
                            return "found"
                        end if
                    end repeat
                end tell
            end tell
            tell application "PyCharm" to activate
            return "not found"
            """]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {}
    }

    private static func activateByProjectName(_ projectName: String, workingDirectory: String) {
        var searchTerms = projectName.components(separatedBy: ":")
        searchTerms += projectName.components(separatedBy: "/")
        searchTerms.append(URL(fileURLWithPath: workingDirectory).lastPathComponent)
        searchTerms = Array(Set(searchTerms.filter { !$0.isEmpty }))

        for term in searchTerms {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", """
                tell application "System Events"
                    tell process "pycharm"
                        repeat with w in windows
                            set wName to name of w as text
                            if wName contains "\(term)" then
                                tell application "PyCharm" to activate
                                perform action "AXRaise" of w
                                return "found"
                            end if
                        end repeat
                    end tell
                end tell
                return "not found"
                """]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if result == "found" {
                    return
                }
            } catch {}
        }

        activateApp("PyCharm")
    }
}
