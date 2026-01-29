import Foundation

/// iTerm2 terminal integration
/// https://iterm2.com/
public struct iTerm2Integration: TerminalIntegration {
    public static let identifier = "iTerm2"
    public static let displayName = "iTerm2"

    public static func matches(processInfo: ProcessInfo) -> Bool {
        let name = processInfo.terminalName.lowercased()
        return name.contains("iterm")
    }

    public static func extractMetadata(processInfo: ProcessInfo) -> [String: String] {
        var metadata: [String: String] = [:]

        // Store TTY for tab identification
        if let tty = processInfo.ttyName, !tty.isEmpty {
            metadata["ttyName"] = tty
        }

        // Try to get session ID if possible
        if let sessionId = getSessionIdForTty(processInfo.ttyName) {
            metadata["itermSessionId"] = sessionId
        }

        return metadata
    }

    public static func activate(session: SessionContext) {
        // Prefer session ID if available
        if let sessionId = session.metadata["itermSessionId"], !sessionId.isEmpty {
            activateBySessionId(sessionId)
            return
        }

        // Try TTY-based navigation
        if let tty = session.ttyName ?? session.metadata["ttyName"], !tty.isEmpty {
            activateByTty(tty)
            return
        }

        // Try to find by working directory
        activateByWorkingDirectory(session.workingDirectory)
    }

    // MARK: - Private Methods

    private static func getSessionIdForTty(_ tty: String?) -> String? {
        guard let tty = tty, !tty.isEmpty else { return nil }

        // iTerm2 provides session info via AppleScript
        let script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s contains "\(tty)" then
                                return id of s
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return ""
            """
        if let result = runAppleScript(script), !result.isEmpty {
            return result
        }
        return nil
    }

    private static func activateBySessionId(_ sessionId: String) {
        let script = """
            tell application "iTerm2"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if id of s is "\(sessionId)" then
                                select t
                                select s
                                return "found"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        executeAppleScript(script)
    }

    private static func activateByTty(_ tty: String) {
        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        let script = """
            tell application "iTerm2"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s contains "\(ttyPath)" then
                                select t
                                select s
                                return "found"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        executeAppleScript(script)
    }

    private static func activateByWorkingDirectory(_ workingDirectory: String) {
        // iTerm2 can report working directory via escape sequences
        // but this requires terminal integration to be set up
        // For now, just activate iTerm2
        let script = """
            tell application "iTerm2"
                activate
                -- Try to find session by path (requires shell integration)
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                set sessionPath to path of s
                                if sessionPath contains "\(workingDirectory)" then
                                    select t
                                    select s
                                    return "found"
                                end if
                            end try
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        executeAppleScript(script)
    }
}
