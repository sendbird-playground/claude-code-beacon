import Foundation
import AppKit
import ApplicationServices

/// macOS Terminal.app integration
public struct TerminalAppIntegration: TerminalIntegration {
    public static let identifier = "Terminal"
    public static let displayName = "Terminal.app"

    private static func log(_ message: String) {
        let logPath = "/tmp/beacon_debug.log"
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [TerminalApp] \(message)\n"
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
        return name.contains("terminal") && !name.contains("wezterm") && !name.contains("iterm")
    }

    public static func extractMetadata(processInfo: ProcessInfo) -> [String: String] {
        var metadata: [String: String] = [:]

        // Store TTY for precise tab navigation
        if let tty = processInfo.ttyName, !tty.isEmpty {
            metadata["ttyName"] = tty
        } else if let tty = getTtyForPid(processInfo.pid) {
            metadata["ttyName"] = tty
        }

        return metadata
    }

    private static func isValidTty(_ tty: String) -> Bool {
        return !tty.isEmpty && tty != "??" && !tty.contains("not a tty")
    }

    public static func activate(session: SessionContext) {
        log("activate: ttyName=\(session.ttyName ?? "nil"), metadata_tty=\(session.metadata["ttyName"] ?? "nil"), pid=\(session.pid.map(String.init) ?? "nil"), workDir=\(session.workingDirectory)")

        // Resolve TTY
        var tty: String? = nil
        if let t = session.ttyName ?? session.metadata["ttyName"], isValidTty(t) {
            tty = t
        } else if let pid = session.pid {
            tty = getTtyForPid(pid)
        }

        if let tty = tty {
            log("resolved TTY: \(tty)")

            // Try osascript first (works if Automation permission granted)
            if activateByTtyViaOsascript(tty) {
                log("osascript succeeded")
                return
            }
            log("osascript failed, trying Accessibility API")
        }

        // Use Accessibility API: match by working directory in tab title
        if activateByAccessibility(workingDirectory: session.workingDirectory) {
            log("Accessibility API succeeded")
            return
        }

        // Fallback: just activate Terminal
        log("falling back to generic activate")
        activateApp("Terminal")
    }

    // MARK: - Private Methods

    private static func getTtyForPid(_ pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "tty="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let tty = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if isValidTty(tty) {
                return tty
            }
        } catch {}
        return nil
    }

    /// Navigate to Terminal tab via osascript subprocess
    private static func activateByTtyViaOsascript(_ tty: String) -> Bool {
        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        log("activateByTtyViaOsascript: ttyPath=\(ttyPath)")

        let script = """
            tell application "Terminal"
                activate
                set targetTTY to "\(ttyPath)"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if tty of t is targetTTY then
                                set selected of t to true
                                set index of w to 1
                                return "found"
                            end if
                        end try
                    end repeat
                end repeat
                return "not found"
            end tell
            """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            log("osascript result: '\(result)', exitCode: \(task.terminationStatus)")
            return result == "found"
        } catch {
            log("osascript error: \(error)")
            return false
        }
    }

    /// Navigate to Terminal tab via macOS Accessibility API
    private static func activateByAccessibility(workingDirectory: String) -> Bool {
        guard let terminalApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Terminal"
        ).first else {
            log("Accessibility: Terminal.app not running")
            return false
        }

        let appPid = terminalApp.processIdentifier
        let appElement = AXUIElementCreateApplication(appPid)

        // Get all windows
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            log("Accessibility: could not get windows")
            return false
        }

        // Build search terms from working directory
        let dirName = URL(fileURLWithPath: workingDirectory).lastPathComponent
        log("Accessibility: searching \(windows.count) windows for '\(dirName)'")

        for window in windows {
            // Find the tab group in this window
            guard let tabGroup = findTabGroup(in: window) else { continue }

            // Get tabs
            var tabsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(tabGroup, kAXTabsAttribute as CFString, &tabsRef) == .success,
                  let tabs = tabsRef as? [AXUIElement] else {
                continue
            }

            for (tabIndex, tab) in tabs.enumerated() {
                // Get tab title
                var titleRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(tab, kAXTitleAttribute as CFString, &titleRef) == .success,
                      let title = titleRef as? String else {
                    continue
                }

                log("Accessibility: window tab[\(tabIndex)] title='\(title)'")

                // Match: tab title contains the directory name
                if title.contains(dirName) {
                    log("Accessibility: matched tab[\(tabIndex)] in window")

                    // Select this tab by pressing it
                    AXUIElementPerformAction(tab, kAXPressAction as CFString)

                    // Raise the window and activate Terminal
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    terminalApp.activate()

                    return true
                }
            }
        }

        log("Accessibility: no matching tab found for '\(dirName)'")
        return false
    }

    /// Find AXTabGroup element within a window
    private static func findTabGroup(in element: AXUIElement) -> AXUIElement? {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String, role == "AXTabGroup" {
            return element
        }

        // Recurse into children
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let tabGroup = findTabGroup(in: child) {
                return tabGroup
            }
        }
        return nil
    }
}
