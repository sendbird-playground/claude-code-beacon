import Foundation
import AppKit
import UserNotifications

// MARK: - Models

enum SessionStatus: String, Codable {
    case running = "running"
    case completed = "completed"
    case acknowledged = "acknowledged"
}


struct ClaudeSession: Identifiable, Codable {
    let id: String
    var projectName: String
    var terminalInfo: String
    var workingDirectory: String
    var status: SessionStatus
    var createdAt: Date
    var completedAt: Date?
    var acknowledgedAt: Date?
    var pid: Int32?
    var summary: String?      // 1-3 word summary (e.g., "fix", "add", "update")
    var details: String?      // Full details for verbose mode
    var tag: String?          // Custom category tag (e.g., "backend", "frontend")

    init(
        id: String = UUID().uuidString,
        projectName: String,
        terminalInfo: String,
        workingDirectory: String,
        status: SessionStatus = .running,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        acknowledgedAt: Date? = nil,
        pid: Int32? = nil,
        summary: String? = nil,
        details: String? = nil,
        tag: String? = nil
    ) {
        self.id = id
        self.projectName = projectName
        self.terminalInfo = terminalInfo
        self.workingDirectory = workingDirectory
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.acknowledgedAt = acknowledgedAt
        self.pid = pid
        self.summary = summary
        self.details = details
        self.tag = tag
    }


    // Display summary with fallback
    var displaySummary: String {
        summary ?? "done"
    }
}

// MARK: - Session Manager

class SessionManager {
    static let shared = SessionManager()

    var sessions: [ClaudeSession] = []
    var onSessionsChanged: (() -> Void)?

    private var monitorTimer: Timer?
    private var appActivationObserver: Any?
    private let storageURL: URL

    private var knownPids: Set<Int32> = []
    private var ignoredPids: Set<Int32> = []  // PIDs to ignore (user marked as complete)
    private let settingsURL: URL

    // Settings
    var notificationEnabled: Bool = true {
        didSet { saveSettings() }
    }

    var soundEnabled: Bool = true {
        didSet { saveSettings() }
    }

    var voiceEnabled: Bool = true {
        didSet { saveSettings() }
    }

    var maxRecentSessions: Int = 10 {
        didSet {
            saveSettings()
            trimOldSessions()
        }
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let beaconDir = appSupport.appendingPathComponent("Beacon")
        try? FileManager.default.createDirectory(at: beaconDir, withIntermediateDirectories: true)
        storageURL = beaconDir.appendingPathComponent("sessions.json")
        settingsURL = beaconDir.appendingPathComponent("settings.json")

        loadSessions()
        loadSettings()
        requestNotificationPermission()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        // Defer initial scan to background to avoid blocking startup
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.scanForSessions()
        }

        // Monitor every 2 seconds for new/completed sessions
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .userInitiated).async {
                self?.scanForSessions()
            }
        }

        // Watch for app activations to auto-acknowledge sessions
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAppActivation(notification)
        }
    }

    private func handleAppActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let appName = app.localizedName else { return }

        // Map app names to our display names for matching
        let reverseMapping: [String: String] = [
            "WezTerm": "WezTerm",
            "wezterm": "WezTerm",
            "iTerm2": "iTerm2",
            "iTerm": "iTerm2",
            "Cursor": "Cursor",
            "Visual Studio Code": "VS Code",
            "Code": "VS Code",
            "PyCharm": "PyCharm",
            "IntelliJ IDEA": "IntelliJ",
            "WebStorm": "WebStorm",
            "GoLand": "GoLand",
            "Rider": "Rider",
            "Terminal": "Terminal",
            "Alacritty": "Alacritty",
            "kitty": "Kitty",
            "Hyper": "Hyper"
        ]

        let normalizedAppName = reverseMapping[appName] ?? appName

        // Check if activated app matches any completed session's terminal
        for session in sessions where session.status == .completed {
            if session.terminalInfo == normalizedAppName ||
               session.terminalInfo.localizedCaseInsensitiveContains(appName) ||
               appName.localizedCaseInsensitiveContains(session.terminalInfo) {
                acknowledgeSession(id: session.id)
            }
        }
    }

    func scanForSessions() {
        let claudeProcesses = findClaudeProcesses()

        // Check for new processes
        for process in claudeProcesses {
            // Skip ignored PIDs (user marked as complete)
            if ignoredPids.contains(process.pid) {
                continue
            }

            if !knownPids.contains(process.pid) {
                knownPids.insert(process.pid)

                // Check if we already have a session for this PID
                if !sessions.contains(where: { $0.pid == process.pid && $0.status == .running }) {
                    let pathURL = URL(fileURLWithPath: process.cwd)
                    let folderName = pathURL.lastPathComponent
                    let parentName = pathURL.deletingLastPathComponent().lastPathComponent

                    // Show "parent/folder" for better context (e.g., "vitess-ops/eagleeye")
                    let projectName = parentName.isEmpty || parentName == "/" ? folderName : "\(parentName)/\(folderName)"

                    let session = ClaudeSession(
                        projectName: projectName,
                        terminalInfo: process.terminal,
                        workingDirectory: process.cwd,
                        status: .running,
                        pid: process.pid
                    )
                    sessions.insert(session, at: 0)
                    saveSessions()
                    onSessionsChanged?()
                }
            }
        }

        // Check for completed processes (running sessions whose PIDs no longer exist)
        let runningPids = Set(claudeProcesses.map { $0.pid })

        for i in sessions.indices {
            if sessions[i].status == .running, let pid = sessions[i].pid {
                if !runningPids.contains(pid) {
                    // Process ended - mark as completed
                    sessions[i].status = .completed
                    sessions[i].completedAt = Date()
                    sendCompletionNotification(for: sessions[i])
                    saveSessions()
                    trimOldSessions()
                    onSessionsChanged?()
                }
            }
        }

        // Clean up old PIDs
        knownPids = knownPids.intersection(runningPids)
        ignoredPids = ignoredPids.intersection(runningPids)
    }

    struct ClaudeProcess {
        let pid: Int32
        let cwd: String
        let terminal: String
    }

    func findClaudeProcesses() -> [ClaudeProcess] {
        var processes: [ClaudeProcess] = []

        // Use ps to find claude processes
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,comm"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Look for claude CLI processes (exclude Claude.app desktop app)
                if (trimmed.contains("claude") || trimmed.contains("Claude")) &&
                   !trimmed.contains("Claude.app") {
                    let parts = trimmed.split(separator: " ", maxSplits: 1)
                    if let pidStr = parts.first, let pid = Int32(pidStr) {
                        // Get working directory for this PID
                        if let cwd = getProcessCwd(pid: pid) {
                            let terminal = getProcessTerminal(pid: pid)
                            processes.append(ClaudeProcess(pid: pid, cwd: cwd, terminal: terminal))
                        }
                    }
                }
            }
        } catch {
            print("Error finding Claude processes: \(error)")
        }

        return processes
    }

    func getProcessCwd(pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("n") && !line.contains("Permission denied") {
                    return String(line.dropFirst())
                }
            }
        } catch {
            // Ignore errors
        }

        return nil
    }

    func getProcessTerminal(pid: Int32) -> String {
        // Check if parent is launchd (PID 1) - orphaned process
        if let ppid = getParentPid(pid), ppid == 1 {
            return "Background"
        }

        // Walk up the process tree to find the parent application
        var currentPid = pid

        for _ in 0..<10 {  // Max 10 levels up
            guard let ppid = getParentPid(currentPid), ppid > 1 else { break }

            if let appName = getAppNameFromPid(ppid) {
                return appName
            }
            currentPid = ppid
        }

        return "Terminal"
    }

    func getParentPid(_ pid: Int32) -> Int32? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "ppid="]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let ppidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Int32(ppidStr)
        } catch {
            return nil
        }
    }

    func getAppNameFromPid(_ pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "comm="]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let comm = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // Check if it's an app (contains .app in path or known app names)
            let lowered = comm.lowercased()

            if lowered.contains("wezterm") {
                return "WezTerm"
            } else if lowered.contains("iterm") {
                return "iTerm2"
            } else if lowered.contains("cursor") {
                return "Cursor"
            } else if lowered.contains("code") && !lowered.contains("claude") {
                return "VS Code"
            } else if lowered.contains("pycharm") {
                return "PyCharm"
            } else if lowered.contains("intellij") {
                return "IntelliJ"
            } else if lowered.contains("webstorm") {
                return "WebStorm"
            } else if lowered.contains("goland") {
                return "GoLand"
            } else if lowered.contains("rider") {
                return "Rider"
            } else if lowered.contains("terminal") && comm.contains(".app") {
                return "Terminal"
            } else if lowered.contains("alacritty") {
                return "Alacritty"
            } else if lowered.contains("kitty") {
                return "Kitty"
            } else if lowered.contains("hyper") {
                return "Hyper"
            } else if comm.contains(".app/") {
                // Extract app name from path like /Applications/Foo.app/Contents/MacOS/foo
                if let range = comm.range(of: "/([^/]+)\\.app/", options: .regularExpression) {
                    let appPath = String(comm[range])
                    let appName = appPath.replacingOccurrences(of: "/", with: "").replacingOccurrences(of: ".app", with: "")
                    return appName
                }
            }
        } catch {
            // Ignore
        }

        return nil
    }

    // MARK: - Session Management

    func acknowledgeSession(id: String) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].status = .acknowledged
            sessions[index].acknowledgedAt = Date()
            saveSessions()
            onSessionsChanged?()
            cancelNotifications(for: id)
        }
    }


    func navigateToSession(id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }

        let appName = session.terminalInfo

        // Special handling for WezTerm - activate specific pane
        if appName == "WezTerm" {
            activateWezTermPane(workingDirectory: session.workingDirectory)
            return
        }

        // Special handling for Terminal.app - activate specific tab by TTY
        if appName.hasPrefix("Terminal"), let pid = session.pid {
            activateTerminalTab(pid: pid, workingDirectory: session.workingDirectory)
            return
        }

        // Use AppleScript for reliable activation across macOS versions
        let script = """
            tell application "\(appName)"
                activate
                reopen
            end tell
            """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }

    func activateTerminalTab(pid: Int32, workingDirectory: String) {
        // Get TTY for the process
        let ttyTask = Process()
        ttyTask.executableURL = URL(fileURLWithPath: "/bin/ps")
        ttyTask.arguments = ["-p", "\(pid)", "-o", "tty="]

        let pipe = Pipe()
        ttyTask.standardOutput = pipe

        var tty = ""
        do {
            try ttyTask.run()
            ttyTask.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            tty = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            // Continue with empty tty
        }

        // Try TTY matching first, then fall back to path matching
        let script = """
            tell application "Terminal"
                -- Try TTY matching first
                if "\(tty)" is not "" and "\(tty)" is not "??" then
                    set targetTTY to "/dev/\(tty)"
                    repeat with w in windows
                        repeat with t in tabs of w
                            try
                                if tty of t is targetTTY then
                                    set selected of t to true
                                    set frontmost of w to true
                                    activate
                                    return "found by tty"
                                end if
                            end try
                        end repeat
                    end repeat
                end if

                -- Fallback: match by working directory in tab name
                set targetPath to "\(workingDirectory)"
                set targetName to do shell script "basename " & quoted form of targetPath
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if name of t contains targetName then
                                set selected of t to true
                                set frontmost of w to true
                                activate
                                return "found by name"
                            end if
                        end try
                    end repeat
                end repeat

                -- Just activate if nothing found
                activate
                return "not found"
            end tell
            """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }

    func activateWezTermPane(workingDirectory: String) {
        // First, get list of panes from WezTerm
        let listTask = Process()
        listTask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        listTask.arguments = ["wezterm", "cli", "list", "--format", "json"]

        let pipe = Pipe()
        listTask.standardOutput = pipe
        listTask.standardError = FileHandle.nullDevice

        do {
            try listTask.run()
            listTask.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            // Parse JSON to find pane with matching CWD
            if let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for pane in panes {
                    if let cwd = pane["cwd"] as? String {
                        // CWD comes as file:///path format
                        let cleanCwd = cwd.replacingOccurrences(of: "file://", with: "")
                        if cleanCwd == workingDirectory {
                            if let paneId = pane["pane_id"] as? Int {
                                // Activate the pane
                                let activateTask = Process()
                                activateTask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                                activateTask.arguments = ["wezterm", "cli", "activate-pane", "--pane-id", "\(paneId)"]
                                try? activateTask.run()
                                activateTask.waitUntilExit()

                                // Also bring WezTerm to front
                                let script = """
                                    tell application "WezTerm"
                                        activate
                                    end tell
                                    """
                                var error: NSDictionary?
                                if let appleScript = NSAppleScript(source: script) {
                                    appleScript.executeAndReturnError(&error)
                                }
                                return
                            }
                        }
                    }
                }
            }
        } catch {
            // Fallback to just activating WezTerm
        }

        // Fallback: just activate WezTerm
        let script = """
            tell application "WezTerm"
                activate
            end tell
            """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }

    func removeSession(id: String) {
        sessions.removeAll { $0.id == id }
        saveSessions()
        onSessionsChanged?()
        cancelNotifications(for: id)
    }

    func forceCompleteSession(id: String) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            // Add PID to ignored list so it won't be re-detected
            if let pid = sessions[index].pid {
                ignoredPids.insert(pid)
            }
            sessions[index].status = .completed
            sessions[index].completedAt = Date()
            saveSessions()
            onSessionsChanged?()
        }
    }

    func killSession(id: String) {
        if let index = sessions.firstIndex(where: { $0.id == id }),
           let pid = sessions[index].pid {
            // Kill the process
            kill(pid, SIGTERM)

            // Remove from sessions
            sessions.remove(at: index)
            saveSessions()
            onSessionsChanged?()
        }
    }

    func clearAcknowledged() {
        sessions.removeAll { $0.status == .acknowledged }
        saveSessions()
        onSessionsChanged?()
    }

    func clearRecent() {
        // Clear all non-running sessions and their notifications
        let nonRunning = sessions.filter { $0.status != .running }
        for session in nonRunning {
            cancelNotifications(for: session.id)
        }
        sessions.removeAll { $0.status != .running }
        saveSessions()
        onSessionsChanged?()
    }

    func clearAll() {
        sessions.removeAll { $0.status != .running }
        saveSessions()
        onSessionsChanged?()
    }

    // MARK: - Notifications

    func sendCompletionNotification(for session: ClaudeSession) {
        // Send macOS notification if enabled
        if notificationEnabled {
            let content = UNMutableNotificationContent()
            content.title = "Claude Task Completed"
            content.body = "\(session.terminalInfo) · \(session.projectName)"
            content.sound = nil  // We handle sound separately
            content.userInfo = ["sessionId": session.id]

            let request = UNNotificationRequest(
                identifier: session.id,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

        // Play sound if enabled
        if soundEnabled {
            playAlertSound()
        }

        // Speak if enabled
        if voiceEnabled {
            speakSummary(session)
        }
    }

    func speakSummary(_ session: ClaudeSession) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        task.arguments = [session.projectName]
        try? task.run()
    }

    func cancelNotifications(for sessionId: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [sessionId])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [sessionId])
    }

    func playAlertSound() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        task.arguments = ["/System/Library/Sounds/Glass.aiff"]
        try? task.run()
    }


    // MARK: - Persistence

    func saveSessions() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sessions)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("Failed to save sessions: \(error)")
        }
    }

    func loadSessions() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = try decoder.decode([ClaudeSession].self, from: data)

            // Reset running sessions to completed if they exist from previous run
            for i in sessions.indices where sessions[i].status == .running {
                sessions[i].status = .completed
                sessions[i].completedAt = Date()
            }
        } catch {
            print("Failed to load sessions: \(error)")
        }
    }

    // MARK: - Settings

    struct BeaconSettings: Codable {
        var notificationEnabled: Bool = true
        var soundEnabled: Bool = true
        var voiceEnabled: Bool = true
        var maxRecentSessions: Int = 10
    }

    func saveSettings() {
        do {
            let settings = BeaconSettings(
                notificationEnabled: notificationEnabled,
                soundEnabled: soundEnabled,
                voiceEnabled: voiceEnabled,
                maxRecentSessions: maxRecentSessions
            )
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            print("Failed to save settings: \(error)")
        }
    }

    func loadSettings() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }

        do {
            let data = try Data(contentsOf: settingsURL)
            let settings = try JSONDecoder().decode(BeaconSettings.self, from: data)
            notificationEnabled = settings.notificationEnabled
            soundEnabled = settings.soundEnabled
            voiceEnabled = settings.voiceEnabled
            maxRecentSessions = settings.maxRecentSessions
        } catch {
            print("Failed to load settings: \(error)")
        }
    }

    func trimOldSessions() {
        let completed = sessions.filter { $0.status != .running }
        if completed.count > maxRecentSessions {
            // Keep only the most recent completed sessions
            let toRemove = completed.dropFirst(maxRecentSessions)
            for session in toRemove {
                cancelNotifications(for: session.id)
            }
            sessions.removeAll { session in
                session.status != .running && toRemove.contains(where: { $0.id == session.id })
            }
            saveSessions()
            onSessionsChanged?()
        }
    }
}

