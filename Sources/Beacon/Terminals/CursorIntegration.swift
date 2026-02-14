import Foundation
import AppKit

/// Cursor IDE integration
/// Uses osascript (AppleScript via subprocess) to find and raise the correct Cursor window by title.
/// The AXUIElement API does not work reliably for Cursor (Electron/todesktop app),
/// so we use the same osascript subprocess approach that works for PyCharm.
public struct CursorIntegration: TerminalIntegration {
    public static let identifier = "Cursor"
    public static let displayName = "Cursor"

    /// Cursor's actual bundle identifier (Electron/todesktop)
    private static let cursorBundleId = "com.todesktop.230313mzl4w4u92"

    /// Process name as seen by System Events
    private static let cursorProcessName = "Cursor"

    private static func log(_ message: String) {
        let logPath = "/tmp/beacon_debug.log"
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [Cursor] \(message)\n"
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
        return name.contains("cursor")
    }

    public static func extractMetadata(processInfo: ProcessInfo) -> [String: String] {
        // Capture the current frontmost Cursor window name at session detection time
        var metadata: [String: String] = [:]
        if let windowName = getCursorWindowForDirectory(processInfo.workingDirectory) {
            metadata["cursorWindow"] = windowName
            log("extractMetadata: matched window='\(windowName)' for cwd=\(processInfo.workingDirectory)")
        } else if let frontWindow = getFrontmostCursorWindowName() {
            metadata["cursorWindow"] = frontWindow
            log("extractMetadata: fallback to frontmost window='\(frontWindow)'")
        }
        return metadata
    }

    public static func activate(session: SessionContext) {
        log("activate: project=\(session.projectName), workDir=\(session.workingDirectory)")

        // Activate Cursor app first
        guard let cursorApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: cursorBundleId
        ).first else {
            log("Cursor not running (bundle: \(cursorBundleId))")
            activateApp("Cursor")
            return
        }

        // Try stored window name from metadata first
        let storedWindow = session.metadata["cursorWindow"]
        if let windowName = storedWindow, !windowName.isEmpty {
            log("trying stored window name: '\(windowName)'")
            if raiseWindow(containing: windowName) {
                cursorApp.activate()
                return
            }
        }

        // Try matching by working directory name
        let dirName = URL(fileURLWithPath: session.workingDirectory).lastPathComponent
        log("trying directory name: '\(dirName)'")
        if raiseWindow(containing: dirName) {
            cursorApp.activate()
            return
        }

        // Try matching by project name
        if session.projectName != dirName {
            log("trying project name: '\(session.projectName)'")
            if raiseWindow(containing: session.projectName) {
                cursorApp.activate()
                return
            }
        }

        // Fallback: just activate Cursor (brings last-active window)
        log("no matching window found, activating Cursor (last-active window)")
        cursorApp.activate()
    }

    // MARK: - Window Management via osascript

    /// Raise a Cursor window whose title contains the search term.
    /// Uses osascript subprocess for reliable window access (AX API doesn't work for Cursor).
    /// Returns true if a matching window was found and raised.
    @discardableResult
    private static func raiseWindow(containing searchTerm: String) -> Bool {
        let script = """
            tell application "System Events"
                tell process "\(cursorProcessName)"
                    set windowList to every window
                    repeat with w in windowList
                        set wName to name of w as text
                        if wName contains "\(escapeAppleScript(searchTerm))" then
                            perform action "AXRaise" of w
                            return "raised:" & wName
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
            if result.hasPrefix("raised:") {
                let windowName = String(result.dropFirst("raised:".count))
                log("raiseWindow: raised '\(windowName)' (search: '\(searchTerm)')")
                return true
            }
            log("raiseWindow: no window containing '\(searchTerm)'")
            return false
        } catch {
            log("raiseWindow error: \(error)")
            return false
        }
    }

    /// Get the Cursor window name that best matches a working directory.
    /// Enumerates all Cursor windows and returns the title containing the directory name.
    private static func getCursorWindowForDirectory(_ workingDirectory: String) -> String? {
        let dirName = URL(fileURLWithPath: workingDirectory).lastPathComponent
        let script = """
            tell application "System Events"
                tell process "\(cursorProcessName)"
                    set windowList to every window
                    repeat with w in windowList
                        set wName to name of w as text
                        if wName contains "\(escapeAppleScript(dirName))" then
                            return wName
                        end if
                    end repeat
                end tell
            end tell
            return ""
            """
        if let result = runOsascript(script), !result.isEmpty {
            return result
        }
        return nil
    }

    /// Get the frontmost Cursor window name
    private static func getFrontmostCursorWindowName() -> String? {
        let script = """
            tell application "System Events"
                tell process "\(cursorProcessName)"
                    set frontWindowName to name of front window
                    return frontWindowName
                end tell
            end tell
            """
        return runOsascript(script)
    }

    // MARK: - Helpers

    /// Run an osascript and return the trimmed result
    private static func runOsascript(_ script: String) -> String? {
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
            let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (result?.isEmpty == true) ? nil : result
        } catch {
            log("runOsascript error: \(error)")
            return nil
        }
    }

    private static func escapeAppleScript(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
