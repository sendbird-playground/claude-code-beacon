import Foundation

/// Generic fallback integration for terminals/IDEs without specific support.
/// This simply activates the app by name.
///
/// If you want to add support for a new terminal, create a new integration
/// file instead of modifying this one.
public struct GenericIntegration: TerminalIntegration {
    public static let identifier = "Generic"
    public static let displayName = "Generic App"

    // This always returns false because it's used as a fallback
    // The TerminalRegistry will use this when no other integration matches
    public static func matches(processInfo: ProcessInfo) -> Bool {
        return false
    }

    public static func activate(session: SessionContext) {
        // Just activate the app by name
        activateApp(session.terminalInfo)
    }

    /// Activate any app by its name
    public static func activateByName(_ appName: String) {
        activateApp(appName)
    }
}
