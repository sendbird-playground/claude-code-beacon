import Foundation

/// macOS Terminal.app integration
public struct TerminalAppIntegration: TerminalIntegration {
    public static let identifier = "Terminal"
    public static let displayName = "Terminal.app"

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

    public static func activate(session: SessionContext) {
        // Prefer TTY-based navigation (most precise)
        if let tty = session.ttyName ?? session.metadata["ttyName"], !tty.isEmpty {
            activateByTty(tty)
            return
        }

        // Try to find TTY from PID
        if let pid = session.pid {
            if let tty = getTtyForPid(pid) {
                activateByTty(tty)
                return
            }
        }

        // Fallback: just activate Terminal
        activateApp("Terminal")
    }

    // MARK: - Private Methods

    private static func getTtyForPid(_ pid: Int32) -> String? {
        let script = """
            do shell script "ps -p \(pid) -o tty= | tr -d ' '"
            """
        if let tty = runAppleScript(script), !tty.isEmpty, tty != "??" {
            return tty
        }
        return nil
    }

    private static func activateByTty(_ tty: String) {
        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        let script = """
            tell application "Terminal"
                activate
                set targetTTY to "\(ttyPath)"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if tty of t is targetTTY then
                                set selected of t to true
                                set frontmost of w to true
                                return "found"
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            """
        executeAppleScript(script)
    }
}
