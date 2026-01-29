import Foundation
import AppKit

// MARK: - Terminal Integration Protocol

/// Protocol for terminal/IDE integrations.
/// Implement this protocol to add support for a new terminal or IDE.
///
/// ## How to add a new integration:
/// 1. Create a new file in the Terminals/ directory (e.g., `MyTerminalIntegration.swift`)
/// 2. Implement the `TerminalIntegration` protocol
/// 3. Register your integration in `TerminalRegistry.swift`
///
/// ## Example:
/// ```swift
/// struct MyTerminalIntegration: TerminalIntegration {
///     static let identifier = "MyTerminal"
///     static let displayName = "My Terminal"
///
///     static func matches(processInfo: ProcessInfo) -> Bool {
///         return processInfo.terminalName.contains("myterminal")
///     }
///
///     static func activate(session: SessionContext) {
///         // Your activation logic here
///     }
/// }
/// ```
public protocol TerminalIntegration {
    /// Unique identifier for this integration (e.g., "WezTerm", "Terminal", "PyCharm")
    static var identifier: String { get }

    /// Human-readable display name
    static var displayName: String { get }

    /// Check if this integration can handle the given process
    /// - Parameter processInfo: Information about the detected process
    /// - Returns: true if this integration should handle the process
    static func matches(processInfo: ProcessInfo) -> Bool

    /// Activate/navigate to the terminal window containing the session
    /// - Parameter session: Context about the session to navigate to
    static func activate(session: SessionContext)

    /// Optional: Extract additional metadata when a session is detected
    /// - Parameter processInfo: Information about the detected process
    /// - Returns: Dictionary of metadata to store with the session
    static func extractMetadata(processInfo: ProcessInfo) -> [String: String]
}

// Default implementation for optional methods
public extension TerminalIntegration {
    static func extractMetadata(processInfo: ProcessInfo) -> [String: String] {
        return [:]
    }
}

// MARK: - Process Information

/// Information about a detected Claude process
public struct ProcessInfo {
    /// Process ID
    public let pid: Int32

    /// Current working directory
    public let workingDirectory: String

    /// Detected terminal/IDE name
    public let terminalName: String

    /// TTY name if available (e.g., "ttys001")
    public let ttyName: String?

    /// Full command line of the parent process
    public let parentCommand: String?

    public init(pid: Int32, workingDirectory: String, terminalName: String, ttyName: String? = nil, parentCommand: String? = nil) {
        self.pid = pid
        self.workingDirectory = workingDirectory
        self.terminalName = terminalName
        self.ttyName = ttyName
        self.parentCommand = parentCommand
    }
}

// MARK: - Session Context

/// Context for session navigation
public struct SessionContext {
    /// Session ID
    public let id: String

    /// Project/directory name
    public let projectName: String

    /// Working directory path
    public let workingDirectory: String

    /// Terminal/IDE name
    public let terminalInfo: String

    /// Process ID (may be nil if process has exited)
    public let pid: Int32?

    /// TTY name if available
    public let ttyName: String?

    /// Additional metadata stored during detection
    public let metadata: [String: String]

    public init(id: String, projectName: String, workingDirectory: String, terminalInfo: String, pid: Int32?, ttyName: String?, metadata: [String: String] = [:]) {
        self.id = id
        self.projectName = projectName
        self.workingDirectory = workingDirectory
        self.terminalInfo = terminalInfo
        self.pid = pid
        self.ttyName = ttyName
        self.metadata = metadata
    }
}

// MARK: - Helper Functions

/// Run an AppleScript and return the result
public func runAppleScript(_ script: String) -> String? {
    var error: NSDictionary?
    guard let appleScript = NSAppleScript(source: script) else { return nil }
    let result = appleScript.executeAndReturnError(&error)
    if error != nil {
        NSLog("AppleScript error: \(error ?? [:])")
    }
    return result.stringValue
}

/// Run an AppleScript without caring about the result
public func executeAppleScript(_ script: String) {
    var error: NSDictionary?
    if let appleScript = NSAppleScript(source: script) {
        appleScript.executeAndReturnError(&error)
    }
}

/// Simply activate an app by name
public func activateApp(_ appName: String) {
    let script = """
        tell application "\(appName)"
            activate
            reopen
        end tell
        """
    executeAppleScript(script)
}

/// Find a binary in common paths
public func findBinary(name: String, paths: [String]) -> String? {
    for path in paths {
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }
    return nil
}
