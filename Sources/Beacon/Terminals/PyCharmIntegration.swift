import Foundation

/// JetBrains PyCharm integration
/// Also serves as a template for other JetBrains IDEs (IntelliJ, WebStorm, etc.)
public struct PyCharmIntegration: TerminalIntegration {
    public static let identifier = "PyCharm"
    public static let displayName = "PyCharm"

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
        // Prefer stored window name (most precise)
        if let windowName = session.metadata["pycharmWindow"], !windowName.isEmpty {
            activateByWindowName(windowName)
            return
        }

        // Try to find window by project name
        activateByProjectName(session.projectName, workingDirectory: session.workingDirectory)
    }

    // MARK: - Private Methods

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
        NSLog("PyCharmIntegration: activating by window name '\(windowName)'")

        let script = """
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
            return "not found, activated PyCharm"
            """
        let result = runAppleScript(script)
        NSLog("PyCharmIntegration: result = \(result ?? "nil")")
    }

    private static func activateByProjectName(_ projectName: String, workingDirectory: String) {
        // Extract potential project names to match against window titles
        var searchTerms = projectName.components(separatedBy: ":")
        searchTerms += projectName.components(separatedBy: "/")
        searchTerms.append(URL(fileURLWithPath: workingDirectory).lastPathComponent)
        searchTerms = Array(Set(searchTerms.filter { !$0.isEmpty }))

        // Try each search term
        for term in searchTerms {
            let script = """
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
                """

            if let result = runAppleScript(script), result == "found" {
                return
            }
        }

        // Fallback: just activate PyCharm
        activateApp("PyCharm")
    }
}
