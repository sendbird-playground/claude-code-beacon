import Foundation

/// WezTerm terminal integration
/// https://wezfurlong.org/wezterm/
public struct WezTermIntegration: TerminalIntegration {
    public static let identifier = "WezTerm"
    public static let displayName = "WezTerm"

    // Common paths where wezterm CLI might be installed
    private static let binaryPaths = [
        "/opt/homebrew/bin/wezterm",
        "/usr/local/bin/wezterm",
        "/Applications/WezTerm.app/Contents/MacOS/wezterm"
    ]

    public static func matches(processInfo: ProcessInfo) -> Bool {
        let name = processInfo.terminalName.lowercased()
        return name.contains("wezterm")
    }

    public static func extractMetadata(processInfo: ProcessInfo) -> [String: String] {
        var metadata: [String: String] = [:]

        // Try to get the current pane ID for more precise navigation later
        if let paneId = getCurrentPaneId(for: processInfo.workingDirectory) {
            metadata["weztermPane"] = paneId
        }

        return metadata
    }

    public static func activate(session: SessionContext) {
        // Prefer pane ID if available (most precise)
        if let paneId = session.metadata["weztermPane"], !paneId.isEmpty {
            activateByPaneId(paneId)
            return
        }

        // Fall back to matching by working directory
        activateByWorkingDirectory(session.workingDirectory)
    }

    // MARK: - Private Methods

    private static func findWezTermBinary() -> String? {
        return findBinary(name: "wezterm", paths: binaryPaths)
    }

    private static func getCurrentPaneId(for workingDirectory: String) -> String? {
        guard let weztermPath = findWezTermBinary() else { return nil }

        // Get pane list as JSON
        let script = """
            do shell script "\(weztermPath) cli list --format json"
            """

        guard let result = runAppleScript(script),
              let data = result.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        // Find pane with matching CWD
        for pane in panes {
            if let cwd = pane["cwd"] as? String {
                let cleanCwd = cwd.replacingOccurrences(of: "file://", with: "")
                if cleanCwd == workingDirectory {
                    if let paneId = pane["pane_id"] as? Int {
                        return String(paneId)
                    }
                }
            }
        }

        return nil
    }

    private static func activateByPaneId(_ paneId: String) {
        guard let weztermPath = findWezTermBinary() else {
            activateApp("WezTerm")
            return
        }

        let script = """
            do shell script "\(weztermPath) cli activate-pane --pane-id \(paneId)"
            tell application "WezTerm" to activate
            """
        executeAppleScript(script)
    }

    private static func activateByWorkingDirectory(_ workingDirectory: String) {
        guard let weztermPath = findWezTermBinary() else {
            activateApp("WezTerm")
            return
        }

        // Get pane list
        let script = """
            do shell script "\(weztermPath) cli list --format json"
            """

        guard let result = runAppleScript(script),
              let data = result.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            activateApp("WezTerm")
            return
        }

        // Find pane with matching CWD
        for pane in panes {
            if let cwd = pane["cwd"] as? String {
                let cleanCwd = cwd.replacingOccurrences(of: "file://", with: "")
                if cleanCwd == workingDirectory {
                    if let paneId = pane["pane_id"] as? Int {
                        activateByPaneId(String(paneId))
                        return
                    }
                }
            }
        }

        // Fallback: just activate WezTerm
        activateApp("WezTerm")
    }
}
