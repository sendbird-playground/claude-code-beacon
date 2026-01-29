import Foundation

/// Registry of all terminal/IDE integrations.
///
/// ## Adding a new integration:
/// 1. Create your integration file in the Terminals/ directory
/// 2. Add it to the `allIntegrations` array below
/// 3. That's it! The registry will automatically use your integration.
///
public class TerminalRegistry {
    /// Shared instance
    public static let shared = TerminalRegistry()

    // MARK: - Register your integrations here!

    /// All available integrations, in order of priority.
    /// More specific integrations should come before generic ones.
    private let allIntegrations: [TerminalIntegration.Type] = [
        // Terminal emulators
        WezTermIntegration.self,
        iTerm2Integration.self,
        TerminalAppIntegration.self,

        // IDEs (JetBrains, VS Code, etc.)
        PyCharmIntegration.self,

        // Add your integration here!
        // Example: MyTerminalIntegration.self,
    ]

    // MARK: - Public API

    /// Find the appropriate integration for a process
    /// - Parameter processInfo: Information about the detected process
    /// - Returns: The matching integration type, or nil if none match
    public func findIntegration(for processInfo: ProcessInfo) -> TerminalIntegration.Type? {
        for integration in allIntegrations {
            if integration.matches(processInfo: processInfo) {
                return integration
            }
        }
        return nil
    }

    /// Get integration by identifier
    /// - Parameter identifier: The integration identifier (e.g., "WezTerm")
    /// - Returns: The integration type, or nil if not found
    public func getIntegration(identifier: String) -> TerminalIntegration.Type? {
        return allIntegrations.first { $0.identifier == identifier }
    }

    /// Activate the appropriate terminal/IDE for a session
    /// - Parameter session: The session to navigate to
    public func activateSession(_ session: SessionContext) {
        // Try to find specific integration
        if let integration = getIntegration(identifier: session.terminalInfo) {
            NSLog("TerminalRegistry: Using \(integration.identifier) integration for \(session.projectName)")
            integration.activate(session: session)
            return
        }

        // Try to match by creating a fake ProcessInfo
        let processInfo = ProcessInfo(
            pid: session.pid ?? 0,
            workingDirectory: session.workingDirectory,
            terminalName: session.terminalInfo,
            ttyName: session.ttyName
        )

        if let integration = findIntegration(for: processInfo) {
            NSLog("TerminalRegistry: Using \(integration.identifier) integration for \(session.projectName)")
            integration.activate(session: session)
            return
        }

        // Fallback to generic activation
        NSLog("TerminalRegistry: No specific integration for '\(session.terminalInfo)', using generic")
        GenericIntegration.activateByName(session.terminalInfo)
    }

    /// Extract metadata for a newly detected session
    /// - Parameter processInfo: Information about the detected process
    /// - Returns: Dictionary of metadata to store
    public func extractMetadata(for processInfo: ProcessInfo) -> [String: String] {
        if let integration = findIntegration(for: processInfo) {
            return integration.extractMetadata(processInfo: processInfo)
        }
        return [:]
    }

    /// List all available integrations
    /// - Returns: Array of (identifier, displayName) tuples
    public func listIntegrations() -> [(identifier: String, displayName: String)] {
        return allIntegrations.map { ($0.identifier, $0.displayName) }
    }

    private init() {}
}
