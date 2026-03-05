import Foundation

/// iTerm2 terminal integration
/// https://iterm2.com/
public struct iTerm2Integration: TerminalIntegration {
    public static let identifier = "iTerm2"
    public static let displayName = "iTerm2"

    private static func log(_ message: String) {
        let logPath = "/tmp/beacon_debug.log"
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [iTerm2] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath),
               let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }
    }

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
        log("activate: itermSessionId=\(session.metadata["itermSessionId"] ?? "nil"), tty=\(session.ttyName ?? session.metadata["ttyName"] ?? "nil"), workDir=\(session.workingDirectory)")

        // Prefer session ID if available
        if let sessionId = session.metadata["itermSessionId"], !sessionId.isEmpty {
            if activateBySessionId(sessionId) {
                log("activate: matched by session ID")
                return
            }
            log("activate: session ID lookup failed, falling back")
        }

        // Try TTY-based navigation
        if let tty = session.ttyName ?? session.metadata["ttyName"], !tty.isEmpty {
            if activateByTty(tty) {
                log("activate: matched by TTY")
                return
            }
            log("activate: TTY lookup failed, falling back")
        }

        // Try to find by working directory
        if activateByWorkingDirectory(session.workingDirectory) {
            log("activate: matched by working directory")
            return
        }

        log("activate: no exact match found, activating iTerm only")
        activateApp("iTerm")
    }

    // MARK: - osascript runner

    /// Run AppleScript via /usr/bin/osascript process (works reliably from LaunchAgents)
    private static func runOsascript(_ script: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if task.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                log("osascript error (exit \(task.terminationStatus)): \(errStr)")
            }
            return output.isEmpty ? nil : output
        } catch {
            log("osascript launch error: \(error)")
            return nil
        }
    }

    // MARK: - Private Methods

    private static func getSessionIdForTty(_ tty: String?) -> String? {
        guard let tty = tty, !tty.isEmpty else { return nil }

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
        if let result = runOsascript(script), !result.isEmpty {
            return result
        }
        return nil
    }

    private static func activateBySessionId(_ sessionId: String) -> Bool {
        // ITERM_SESSION_ID format is "w0t0p0:GUID" - extract unique ID for matching
        let uniqueId = sessionId.contains(":") ? String(sessionId.split(separator: ":").last ?? Substring(sessionId)) : sessionId

        let script = """
            tell application "iTerm2"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            set sid to id of s as text
                            if sid contains "\(uniqueId)" then
                                select t
                                select s
                                tell w to select
                                return "found"
                            end if
                        end repeat
                    end repeat
                end repeat
                return "not found"
            end tell
            """
        let result = runOsascript(script) ?? ""
        log("activateBySessionId result: '\(result)'")
        return result == "found"
    }

    private static func activateByTty(_ tty: String) -> Bool {
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
                                tell w to select
                                return "found"
                            end if
                        end repeat
                    end repeat
                end repeat
                return "not found"
            end tell
            """
        let result = runOsascript(script) ?? ""
        log("activateByTty result: '\(result)'")
        return result == "found"
    }

    private static func activateByWorkingDirectory(_ workingDirectory: String) -> Bool {
        let script = """
            tell application "iTerm2"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                set sessionPath to path of s
                                if sessionPath contains "\(workingDirectory)" then
                                    select t
                                    select s
                                    tell w to select
                                    return "found"
                                end if
                            end try
                        end repeat
                    end repeat
                end repeat
                return "not found"
            end tell
            """
        let result = runOsascript(script) ?? ""
        log("activateByWorkingDirectory result: '\(result)'")
        return result == "found"
    }
}
