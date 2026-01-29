# Contributing Terminal/IDE Integrations

Thank you for contributing to Beacon! This guide explains how to add support for new terminals or IDEs.

## Quick Start

1. Create a new file in `Sources/Beacon/Terminals/` (e.g., `MyTerminalIntegration.swift`)
2. Implement the `TerminalIntegration` protocol
3. Register your integration in `TerminalRegistry.swift`
4. Submit a PR!

## Example Integration

Here's a minimal example:

```swift
import Foundation

public struct MyTerminalIntegration: TerminalIntegration {
    public static let identifier = "MyTerminal"
    public static let displayName = "My Terminal"

    public static func matches(processInfo: ProcessInfo) -> Bool {
        // Return true if this integration should handle this process
        return processInfo.terminalName.lowercased().contains("myterminal")
    }

    public static func activate(session: SessionContext) {
        // Navigate to the terminal window/tab containing the session
        activateApp("MyTerminal")
    }
}
```

## Protocol Methods

### Required

- **`identifier`**: Unique string identifier (e.g., "WezTerm", "iTerm2")
- **`displayName`**: Human-readable name for UI
- **`matches(processInfo:)`**: Return `true` if your integration handles this process
- **`activate(session:)`**: Navigate to the correct window/tab/pane

### Optional

- **`extractMetadata(processInfo:)`**: Extract extra data during session detection (e.g., pane ID, window name)

## Available Context

### ProcessInfo (during detection)

```swift
struct ProcessInfo {
    let pid: Int32              // Process ID
    let workingDirectory: String // Current directory
    let terminalName: String    // Detected terminal name
    let ttyName: String?        // TTY if available
    let parentCommand: String?  // Parent process command
}
```

### SessionContext (during activation)

```swift
struct SessionContext {
    let id: String              // Session ID
    let projectName: String     // Project/directory name
    let workingDirectory: String
    let terminalInfo: String    // Terminal name
    let pid: Int32?             // May be nil if process exited
    let ttyName: String?
    let metadata: [String: String] // Data from extractMetadata
}
```

## Helper Functions

These are available for your integration:

```swift
// Run AppleScript and get result
runAppleScript(_ script: String) -> String?

// Run AppleScript without caring about result
executeAppleScript(_ script: String)

// Simply activate an app
activateApp(_ appName: String)

// Find a binary in common paths
findBinary(name: String, paths: [String]) -> String?
```

## Tips

### Detecting Your Terminal

The `terminalName` is detected from the parent process. Common patterns:

```swift
// Check contains (case-insensitive)
processInfo.terminalName.lowercased().contains("myterminal")

// Check exact match
processInfo.terminalName == "MyTerminal"

// Check process path
processInfo.parentCommand?.contains("MyTerminal.app")
```

### Precise Navigation

The best integrations can navigate to the exact tab/pane:

1. **Store metadata during detection**: Use `extractMetadata` to capture tab ID, pane ID, etc.
2. **Use metadata during activation**: Read from `session.metadata`

Example:

```swift
public static func extractMetadata(processInfo: ProcessInfo) -> [String: String] {
    var metadata: [String: String] = [:]
    if let paneId = getCurrentPaneId() {
        metadata["paneId"] = paneId
    }
    return metadata
}

public static func activate(session: SessionContext) {
    if let paneId = session.metadata["paneId"] {
        activateByPaneId(paneId)
    } else {
        activateApp("MyTerminal")
    }
}
```

### AppleScript Tips

Most macOS apps can be controlled via AppleScript:

```applescript
-- Activate an app
tell application "MyTerminal" to activate

-- Access windows via System Events
tell application "System Events"
    tell process "myterminal"
        -- List windows, click buttons, etc.
    end tell
end tell
```

### CLI Tools

Some terminals have CLI tools (like `wezterm cli`):

```swift
let script = """
    do shell script "/path/to/cli command"
    """
if let result = runAppleScript(script) {
    // Parse result
}
```

## Register Your Integration

Add your integration to `TerminalRegistry.swift`:

```swift
private let allIntegrations: [TerminalIntegration.Type] = [
    WezTermIntegration.self,
    iTerm2Integration.self,
    TerminalAppIntegration.self,
    PyCharmIntegration.self,
    MyTerminalIntegration.self,  // Add here!
]
```

## Testing

1. Build the app: `./build.sh`
2. Install: `./install.sh`
3. Start a Claude session in your terminal
4. Complete the session and click the notification
5. Verify it navigates to the correct window/tab

## Questions?

Open an issue on GitHub if you need help!
