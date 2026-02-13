import Foundation
import AppKit
import ApplicationServices

/// Cursor IDE integration
/// Uses macOS Accessibility API to match windows by workspace/folder name in title.
public struct CursorIntegration: TerminalIntegration {
    public static let identifier = "Cursor"
    public static let displayName = "Cursor"

    /// Cursor's bundle identifier
    private static let bundleIdentifier = "com.todesktop.230313mzl4w4u92"

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
        // Cursor reports as "vscode" in TERM_PROGRAM, but also match "cursor" directly
        return name.contains("cursor") || name.contains("vscode")
    }

    public static func extractMetadata(processInfo: ProcessInfo) -> [String: String] {
        return [:]
    }

    public static func activate(session: SessionContext) {
        log("activate: project=\(session.projectName), workDir=\(session.workingDirectory), terminal=\(session.terminalInfo)")

        // Try Accessibility API window matching first
        if activateByAccessibility(workingDirectory: session.workingDirectory) {
            log("Accessibility API succeeded")
            return
        }

        // Fallback: just activate Cursor
        log("falling back to generic activate")
        activateApp("Cursor")
    }

    // MARK: - Accessibility API

    /// Find and raise the Cursor window whose title contains the workspace directory name
    private static func activateByAccessibility(workingDirectory: String) -> Bool {
        guard let cursorApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else {
            log("Accessibility: Cursor not running")
            return false
        }

        let appPid = cursorApp.processIdentifier
        let appElement = AXUIElementCreateApplication(appPid)

        // Get all windows
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            log("Accessibility: could not get windows")
            return false
        }

        // Build search term from working directory basename
        let dirName = URL(fileURLWithPath: workingDirectory).lastPathComponent
        log("Accessibility: searching \(windows.count) windows for '\(dirName)'")

        for (index, window) in windows.enumerated() {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String else {
                continue
            }

            log("Accessibility: window[\(index)] title='\(title)'")

            // Cursor window titles are like "Beacon - Cursor" or "filename - project - Cursor"
            if title.contains(dirName) {
                log("Accessibility: matched window[\(index)]")

                // Raise the window and activate Cursor
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                cursorApp.activate()

                return true
            }
        }

        log("Accessibility: no matching window found for '\(dirName)'")
        return false
    }
}
