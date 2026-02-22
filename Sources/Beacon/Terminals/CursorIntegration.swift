import Foundation
import AppKit

/// Cursor IDE integration using Beacon Terminal Navigator extension.
///
/// Uses a VS Code extension that runs an HTTP server in each Cursor window.
/// Each extension instance registers in ~/.beacon-ide/registry.json with:
/// - windowId, port, pid, workspaceFolders, terminalPids
///
/// At session detection: walks the claude process's parent chain to find
/// which extension instance owns the terminal, stores windowId + port.
///
/// At activation: sends POST /focus to the stored port, bringing the
/// correct Cursor window and terminal to front.
///
/// Falls back to `open -a Cursor <workDir>` when the extension is not available.
public struct CursorIntegration: TerminalIntegration {
    public static let identifier = "Cursor"
    public static let displayName = "Cursor"

    private static let cursorBundleId = "com.todesktop.230313mzl4w4u92"
    private static let registryPath = NSHomeDirectory() + "/.beacon-ide/registry.json"

    private static func log(_ message: String) {
        let logPath = "/tmp/beacon_debug.log"
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [Cursor] \(message)\n"
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
        return name.contains("cursor")
    }

    // MARK: - Metadata extraction (at session detection time)

    public static func extractMetadata(processInfo: ProcessInfo) -> [String: String] {
        var metadata: [String: String] = [:]

        // Read the extension registry
        guard let entries = readRegistry() else {
            log("extractMetadata: no registry file")
            return metadata
        }

        log("extractMetadata: registry has \(entries.count) entries, claude PID=\(processInfo.pid)")

        // Walk parent chain from claude PID to find the shell PID
        // that matches a terminal PID in the registry
        var ancestorPids: [Int32] = []
        var currentPid = processInfo.pid
        for _ in 0..<15 {
            guard let ppid = getParentPid(currentPid), ppid > 1 else { break }
            ancestorPids.append(ppid)
            currentPid = ppid
        }

        log("extractMetadata: ancestor PIDs = \(ancestorPids)")

        // Find registry entry whose terminalPids contains one of our ancestors
        for entry in entries {
            let termPids = entry["terminalPids"] as? [Int] ?? []
            for ancestorPid in ancestorPids {
                if termPids.contains(Int(ancestorPid)) {
                    if let windowId = entry["windowId"] as? String,
                       let port = entry["port"] as? Int {
                        metadata["cursorWindowId"] = windowId
                        metadata["cursorPort"] = String(port)
                        log("extractMetadata: matched windowId=\(windowId) port=\(port) via shell PID=\(ancestorPid)")
                        return metadata
                    }
                }
            }
        }

        // Fallback: match by workspace folder
        for entry in entries {
            let folders = entry["workspaceFolders"] as? [String] ?? []
            if folders.contains(processInfo.workingDirectory) {
                if let windowId = entry["windowId"] as? String,
                   let port = entry["port"] as? Int {
                    metadata["cursorWindowId"] = windowId
                    metadata["cursorPort"] = String(port)
                    log("extractMetadata: matched windowId=\(windowId) port=\(port) via workspace folder")
                    return metadata
                }
            }
        }

        log("extractMetadata: no matching registry entry")
        return metadata
    }

    // MARK: - Activation (when user clicks a session)

    public static func activate(session: SessionContext) {
        log("activate: project=\(session.projectName), workDir=\(session.workingDirectory)")

        // Try the extension's focus endpoint using stored port
        if let portStr = session.metadata["cursorPort"],
           let port = Int(portStr) {
            log("trying plugin focus on port \(port)")
            if sendFocusRequest(port: port) {
                log("plugin focus succeeded on port \(port)")
                // Also activate the app to ensure it comes to front
                if let cursorApp = NSRunningApplication.runningApplications(
                    withBundleIdentifier: cursorBundleId
                ).first {
                    cursorApp.activate()
                }
                return
            }
            log("plugin focus failed on port \(port), trying re-discovery")
        }

        // Re-discover: the port may have changed since detection
        if let entry = findRegistryEntry(for: session) {
            if let port = entry["port"] as? Int {
                log("re-discovered port \(port), trying focus")
                if sendFocusRequest(port: port) {
                    log("re-discovered plugin focus succeeded")
                    if let cursorApp = NSRunningApplication.runningApplications(
                        withBundleIdentifier: cursorBundleId
                    ).first {
                        cursorApp.activate()
                    }
                    return
                }
            }
        }

        // Fallback: use `open -a Cursor <workDir>`
        let workDir = session.workingDirectory
        if !workDir.isEmpty {
            log("falling back to open -a Cursor '\(workDir)'")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", "Cursor", workDir]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    log("open -a Cursor succeeded")
                    return
                }
            } catch {}
        }

        log("all strategies failed, generic activate")
        activateApp("Cursor")
    }

    // MARK: - Registry

    /// Read the Beacon IDE extension registry file
    private static func readRegistry() -> [[String: Any]]? {
        guard FileManager.default.fileExists(atPath: registryPath),
              let data = FileManager.default.contents(atPath: registryPath),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return entries
    }

    /// Find a registry entry matching a session (by windowId, then workspace folder)
    private static func findRegistryEntry(for session: SessionContext) -> [String: Any]? {
        guard let entries = readRegistry() else { return nil }

        // Match by stored windowId
        if let storedWindowId = session.metadata["cursorWindowId"] {
            for entry in entries {
                if let wid = entry["windowId"] as? String, wid == storedWindowId {
                    return entry
                }
            }
        }

        // Match by workspace folder
        for entry in entries {
            let folders = entry["workspaceFolders"] as? [String] ?? []
            if folders.contains(session.workingDirectory) {
                return entry
            }
        }

        return nil
    }

    // MARK: - Plugin Communication

    /// Send a focus request to the extension's HTTP server
    private static func sendFocusRequest(port: Int) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = [
            "-s", "-o", "/dev/null", "-w", "%{http_code}",
            "--connect-timeout", "1",
            "--max-time", "3",
            "-X", "POST",
            "http://127.0.0.1:\(port)/focus",
            "-H", "Content-Type: application/json",
            "-d", "{}"
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let httpCode = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            log("sendFocusRequest port=\(port) HTTP \(httpCode)")
            return httpCode == "200"
        } catch {
            log("sendFocusRequest error: \(error)")
            return false
        }
    }

    // MARK: - Extension Detection & Installation

    /// Check if the Beacon VS Code extension is installed in Cursor
    public static func isExtensionInstalled() -> Bool {
        let extensionDir = NSHomeDirectory() + "/.cursor/extensions/sendbird.beacon-terminal-navigator-1.0.0"
        return FileManager.default.fileExists(atPath: extensionDir)
    }

    /// Check if any registered Cursor extension instance is alive (extension is active)
    public static func isExtensionActive() -> Bool {
        guard let entries = readRegistry() else { return false }
        for entry in entries {
            let appName = entry["appName"] as? String ?? ""
            guard appName.lowercased().contains("cursor") else { continue }
            if let pid = entry["pid"] as? Int, pid > 0 {
                // Check if the process is still alive
                let alive = kill(Int32(pid), 0) == 0
                if alive { return true }
            }
        }
        return false
    }

    /// Install the Beacon extension into Cursor using the CLI.
    /// Returns (success, errorMessage)
    public static func installExtension() -> (Bool, String?) {
        // Find the VSIX bundled with the app or in the repo
        let vsixPaths = [
            Bundle.main.resourcePath.map { $0 + "/beacon-terminal-navigator-1.0.0.vsix" },
            Bundle.main.bundlePath + "/Contents/Resources/beacon-terminal-navigator-1.0.0.vsix",
        ].compactMap { $0 }

        // Also check the repo cursor-extension directory relative to the executable
        let repoVsixPath = (Bundle.main.bundlePath as NSString)
            .deletingLastPathComponent + "/cursor-extension/beacon-terminal-navigator-1.0.0.vsix"

        let allPaths = vsixPaths + [repoVsixPath]

        var vsixPath: String?
        for path in allPaths {
            if FileManager.default.fileExists(atPath: path) {
                vsixPath = path
                break
            }
        }

        guard let foundVsix = vsixPath else {
            return (false, "VSIX file not found")
        }

        // Use Cursor CLI to install
        let cursorCli = "/usr/local/bin/cursor"
        guard FileManager.default.fileExists(atPath: cursorCli) else {
            return (false, "Cursor CLI not found at \(cursorCli)")
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: cursorCli)
        task.arguments = ["--install-extension", foundVsix]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if task.terminationStatus == 0 {
                log("installExtension: success — \(output)")
                return (true, nil)
            } else {
                log("installExtension: failed — \(output)")
                return (false, output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch {
            log("installExtension: error — \(error)")
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Process Helpers

    /// Get parent PID of a process
    private static func getParentPid(_ pid: Int32) -> Int32? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "ppid="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let ppidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Int32(ppidStr)
        } catch {
            return nil
        }
    }
}
