import Foundation
import AppKit
import UserNotifications
import Network

// MARK: - Models

enum SessionStatus: String, Codable {
    case running = "running"
    case completed = "completed"
    case acknowledged = "acknowledged"
}

// MARK: - Session Group

struct SessionGroup: Identifiable, Codable {
    let id: String
    var name: String
    var colorHex: String  // Hex color string (e.g., "#FF5733")
    var order: Int

    // Group-level settings overrides (nil = use global setting)
    var notificationOverride: Bool?
    var soundOverride: Bool?
    var voiceOverride: Bool?
    var reminderOverride: Bool?

    init(
        id: String = UUID().uuidString,
        name: String,
        colorHex: String = "#808080",
        order: Int = 0,
        notificationOverride: Bool? = nil,
        soundOverride: Bool? = nil,
        voiceOverride: Bool? = nil,
        reminderOverride: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.order = order
        self.notificationOverride = notificationOverride
        self.soundOverride = soundOverride
        self.voiceOverride = voiceOverride
        self.reminderOverride = reminderOverride
    }

    // Predefined pastel colors for easy selection
    static let availableColors: [(name: String, hex: String)] = [
        ("Rose", "#FFB3BA"),
        ("Peach", "#FFDFBA"),
        ("Mint", "#BAFFC9"),
        ("Sky", "#BAE1FF"),
        ("Lavender", "#E0BBE4")
    ]
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

    // Navigation hints from hook
    var weztermPane: String?  // WezTerm pane ID
    var ttyName: String?      // TTY name for Terminal.app
    var pycharmWindow: String? // PyCharm window/project name

    // Per-session settings overrides (nil = use global setting)
    var notificationOverride: Bool?
    var soundOverride: Bool?
    var voiceOverride: Bool?
    var reminderOverride: Bool?

    // Group assignment (nil = ungrouped)
    var groupId: String?

    // Reminder tracking - when alert was first triggered and how many reminders sent
    var alertTriggeredAt: Date?
    var remindersSent: Int = 0

    // Manual ordering within group (lower = higher in list)
    var orderInGroup: Int = 0

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
        tag: String? = nil,
        weztermPane: String? = nil,
        ttyName: String? = nil,
        pycharmWindow: String? = nil,
        notificationOverride: Bool? = nil,
        soundOverride: Bool? = nil,
        voiceOverride: Bool? = nil,
        reminderOverride: Bool? = nil,
        groupId: String? = nil,
        alertTriggeredAt: Date? = nil,
        remindersSent: Int = 0,
        orderInGroup: Int = 0
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
        self.weztermPane = weztermPane
        self.ttyName = ttyName
        self.pycharmWindow = pycharmWindow
        self.notificationOverride = notificationOverride
        self.soundOverride = soundOverride
        self.voiceOverride = voiceOverride
        self.reminderOverride = reminderOverride
        self.groupId = groupId
        self.alertTriggeredAt = alertTriggeredAt
        self.remindersSent = remindersSent
        self.orderInGroup = orderInGroup
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
    var groups: [SessionGroup] = []
    var onSessionsChanged: (() -> Void)?

    private var monitorTimer: Timer?
    private var appActivationObserver: Any?
    private let storageURL: URL
    private let groupsURL: URL

    private var knownPids: Set<Int32> = []
    private var ignoredPids: Set<Int32> = []  // PIDs to ignore (user marked as complete)
    private let settingsURL: URL
    private let scanQueue = DispatchQueue(label: "com.beacon.scanQueue")  // Serial queue to prevent race conditions
    private var httpListener: NWListener?
    private var processMonitors: [Int32: DispatchSourceProcess] = [:]  // PID -> dispatch source for exit monitoring

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

    // Reminder settings
    var reminderEnabled: Bool = false {
        didSet { saveSettings() }
    }

    var reminderInterval: Int = 60 {  // seconds
        didSet { saveSettings() }
    }

    var reminderCount: Int = 3 {
        didSet { saveSettings() }
    }

    // Voice pronunciation rules: "pattern" -> "pronunciation"
    var pronunciationRules: [String: String] = [:] {
        didSet { saveSettings() }
    }

    // Track reminder counts per session
    private var reminderCounts: [String: Int] = [:]

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let beaconDir = appSupport.appendingPathComponent("Beacon")
        try? FileManager.default.createDirectory(at: beaconDir, withIntermediateDirectories: true)
        storageURL = beaconDir.appendingPathComponent("sessions.json")
        settingsURL = beaconDir.appendingPathComponent("settings.json")
        groupsURL = beaconDir.appendingPathComponent("groups.json")

        loadSessions()
        loadGroups()
        loadSettings()
        registerNotificationCategories()
        requestNotificationPermission()
        startHttpServer()
        restoreReminders()
    }

    // MARK: - HTTP Server for Hook Data

    private func startHttpServer() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            httpListener = try NWListener(using: params, on: 19876)

            httpListener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            httpListener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("Beacon HTTP server listening on port 19876")
                case .failed(let error):
                    print("Beacon HTTP server failed: \(error)")
                default:
                    break
                }
            }

            httpListener?.start(queue: .global())
        } catch {
            print("Failed to start HTTP server: \(error)")
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global())

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let data = data, let self = self else {
                connection.cancel()
                return
            }

            // Parse HTTP request to extract JSON body
            if let requestString = String(data: data, encoding: .utf8),
               let jsonStart = requestString.range(of: "\r\n\r\n")?.upperBound {
                let jsonString = String(requestString[jsonStart...])
                self.handleHookData(jsonString)
            }

            // Send HTTP 200 response
            let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func handleHookData(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let projectName = json["projectName"] as? String ?? "Unknown"
        let terminalInfo = json["terminalInfo"] as? String ?? "Terminal"
        let workingDirectory = json["workingDirectory"] as? String ?? ""
        let summary = json["summary"] as? String
        let details = json["details"] as? String
        let tag = json["tag"] as? String
        let weztermPane = json["weztermPane"] as? String
        let ttyName = json["ttyName"] as? String
        let pycharmWindow = json["pycharmWindow"] as? String

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Find existing running session with same working directory or create new completed session
            if let index = self.sessions.firstIndex(where: {
                $0.workingDirectory == workingDirectory && $0.status == .running
            }) {
                // Update existing session with hook data and mark completed
                self.sessions[index].summary = summary
                self.sessions[index].details = details
                self.sessions[index].tag = tag
                self.sessions[index].weztermPane = weztermPane
                self.sessions[index].ttyName = ttyName
                self.sessions[index].pycharmWindow = pycharmWindow
                self.sessions[index].status = .completed
                self.sessions[index].completedAt = Date()
                self.sendCompletionNotification(for: self.sessions[index])
            } else {
                // Create new completed session from hook
                let session = ClaudeSession(
                    projectName: projectName,
                    terminalInfo: terminalInfo,
                    workingDirectory: workingDirectory,
                    status: .completed,
                    completedAt: Date(),
                    summary: summary,
                    details: details,
                    tag: tag,
                    weztermPane: weztermPane,
                    ttyName: ttyName,
                    pycharmWindow: pycharmWindow
                )
                self.sessions.insert(session, at: 0)
                self.sendCompletionNotification(for: session)
            }

            self.saveSessions()
            self.trimOldSessions()
            self.onSessionsChanged?()
        }
    }

    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()

        // Check current authorization status first
        center.getNotificationSettings { settings in
            NSLog("Notification authorization status: \(settings.authorizationStatus.rawValue)")
            NSLog("Alert setting: \(settings.alertSetting.rawValue)")
            NSLog("Sound setting: \(settings.soundSetting.rawValue)")
            NSLog("Badge setting: \(settings.badgeSetting.rawValue)")

            switch settings.authorizationStatus {
            case .notDetermined:
                // Request provisional authorization first (doesn't require user interaction)
                // This helps the app appear in System Settings > Notifications
                // Then request full authorization which may show a dialog
                center.requestAuthorization(options: [.alert, .sound, .badge, .provisional]) { granted, error in
                    NSLog("Notification permission granted: \(granted)")
                    if let error = error {
                        NSLog("Notification permission error: \(error)")
                    }

                    // If provisional granted, also request full authorization
                    if granted {
                        center.requestAuthorization(options: [.alert, .sound, .badge]) { fullGranted, fullError in
                            NSLog("Full notification permission granted: \(fullGranted)")
                            if let fullError = fullError {
                                NSLog("Full notification permission error: \(fullError)")
                            }
                        }
                    }
                }
            case .denied:
                NSLog("Notifications are denied. Please enable in System Settings > Notifications > Beacon")
            case .authorized, .provisional, .ephemeral:
                NSLog("Notifications are authorized")
            @unknown default:
                break
            }
        }
    }

    // MARK: - Monitoring

    /// Thread-safe method to trigger a scan from any thread
    func triggerScan() {
        scanQueue.async { [weak self] in
            self?.scanForSessions()
        }
    }

    func startMonitoring() {
        // Defer initial scan to background to avoid blocking startup
        scanQueue.async { [weak self] in
            self?.scanForSessions()
        }

        // Monitor every 5 seconds for new sessions (termination is handled by process monitors)
        // Use serial scanQueue to prevent race conditions causing duplicate notifications
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.scanQueue.async {
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

    /// Start monitoring a specific process for termination (immediate notification)
    /// Must be called on scanQueue
    private func startProcessExitMonitor(pid: Int32) {
        // Skip if already monitoring this PID
        guard processMonitors[pid] == nil else { return }

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: scanQueue)

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            NSLog("Process \(pid) exited - triggering immediate refresh")
            // Already on scanQueue, handle directly
            self.handleProcessExitOnScanQueue(pid: pid)
        }

        // Don't modify dictionary in cancel handler - we do it in stop method
        source.setCancelHandler { }

        processMonitors[pid] = source
        source.resume()
        NSLog("Started exit monitor for PID \(pid)")
    }

    /// Handle immediate process exit notification
    /// Must be called on scanQueue
    private func handleProcessExitOnScanQueue(pid: Int32) {
        // Find session with this PID and mark as completed
        if let index = self.sessions.firstIndex(where: { $0.pid == pid && $0.status == .running }) {
            self.sessions[index].status = .completed
            self.sessions[index].completedAt = Date()

            let session = self.sessions[index]
            NSLog("Session marked completed via exit monitor: \(session.projectName)")

            // Send notification (thread-safe)
            self.sendCompletionNotification(for: session)
            self.saveSessions()
            self.trimOldSessions()

            // UI update on main thread
            DispatchQueue.main.async { [weak self] in
                self?.onSessionsChanged?()
            }
        }

        // Clean up the monitor (on scanQueue)
        stopProcessExitMonitor(pid: pid)

        // Remove from known PIDs
        self.knownPids.remove(pid)
    }

    /// Stop monitoring a process
    /// Must be called on scanQueue
    private func stopProcessExitMonitor(pid: Int32) {
        if let source = processMonitors.removeValue(forKey: pid) {
            source.cancel()
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
        NSLog("scanForSessions: starting scan, knownPids=\(knownPids.count), sessions=\(sessions.count)")
        let claudeProcesses = findClaudeProcesses()
        var needsUIUpdate = false

        // Check for new processes or processes that need to be re-activated
        for process in claudeProcesses {
            // Skip ignored PIDs (user marked as complete)
            if ignoredPids.contains(process.pid) {
                NSLog("scanForSessions: skipping ignored PID \(process.pid)")
                continue
            }

            // Check if we have a running session for this PID
            let hasRunningSession = sessions.contains(where: { $0.pid == process.pid && $0.status == .running })

            if !hasRunningSession {
                // Either new PID or existing PID whose session was acknowledged/completed
                // but process is still running - need to create a new running session
                knownPids.insert(process.pid)

                // Try to find git root for better project name
                let projectName = getProjectName(for: process.cwd, terminal: process.terminal)

                // Get PyCharm window name if this is a PyCharm session
                var pycharmWindow: String? = nil
                if process.terminal == "PyCharm" {
                    pycharmWindow = getFrontmostPyCharmWindow()
                }

                // Inherit groupId from previous session with same working directory
                let inheritedGroupId = sessions.first(where: {
                    $0.workingDirectory == process.cwd && $0.groupId != nil
                })?.groupId

                let session = ClaudeSession(
                    projectName: projectName,
                    terminalInfo: process.terminal,
                    workingDirectory: process.cwd,
                    status: .running,
                    pid: process.pid,
                    weztermPane: process.weztermPane,
                    ttyName: process.ttyName,
                    pycharmWindow: pycharmWindow,
                    groupId: inheritedGroupId
                )
                sessions.insert(session, at: 0)
                saveSessions()
                needsUIUpdate = true
                NSLog("scanForSessions: created session for PID \(process.pid), project=\(projectName), groupId=\(inheritedGroupId ?? "none")")

                // Start monitoring this process for immediate exit notification
                startProcessExitMonitor(pid: process.pid)
            }
        }

        // Check for completed processes (running sessions whose PIDs no longer exist)
        // This is a fallback in case process monitors miss something
        let runningPids = Set(claudeProcesses.map { $0.pid })

        for i in sessions.indices {
            if sessions[i].status == .running, let pid = sessions[i].pid {
                if !runningPids.contains(pid) {
                    // Process ended - mark as completed (fallback if exit monitor didn't catch it)
                    sessions[i].status = .completed
                    sessions[i].completedAt = Date()
                    sendCompletionNotification(for: sessions[i])
                    saveSessions()
                    trimOldSessions()
                    needsUIUpdate = true

                    // Clean up monitor if it exists
                    stopProcessExitMonitor(pid: pid)
                }
            }
        }

        // Clean up old PIDs and monitors
        let stalePids = knownPids.subtracting(runningPids)
        for pid in stalePids {
            stopProcessExitMonitor(pid: pid)
        }
        knownPids = knownPids.intersection(runningPids)
        ignoredPids = ignoredPids.intersection(runningPids)

        // UI updates must happen on main thread
        if needsUIUpdate {
            DispatchQueue.main.async { [weak self] in
                self?.onSessionsChanged?()
            }
        }
    }

    struct ClaudeProcess {
        let pid: Int32
        let cwd: String
        let terminal: String
        let ttyName: String?
        let weztermPane: String?
    }

    func getFrontmostPyCharmWindow() -> String? {
        let script = """
            tell application "System Events"
                tell process "pycharm"
                    set frontWindowName to name of front window
                    -- Extract project name (before " – ")
                    set AppleScript's text item delimiters to " – "
                    set projectName to first text item of frontWindowName
                    return projectName
                end tell
            end tell
            """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script),
           let result = appleScript.executeAndReturnError(&error).stringValue {
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    func getProjectName(for cwd: String, terminal: String) -> String {
        // For PyCharm, try to get project name from window titles
        if terminal == "PyCharm" {
            if let pyCharmProject = getPyCharmProjectForPath(cwd) {
                // Show PyCharm project and working directory if different
                let cwdName = URL(fileURLWithPath: cwd).lastPathComponent
                if pyCharmProject.lowercased() != cwdName.lowercased() {
                    return "\(pyCharmProject):\(cwdName)"
                }
                return pyCharmProject
            }
        }

        // Try to find git root for better project name
        let gitTask = Process()
        gitTask.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitTask.arguments = ["-C", cwd, "rev-parse", "--show-toplevel"]
        gitTask.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let pipe = Pipe()
        gitTask.standardOutput = pipe
        gitTask.standardError = FileHandle.nullDevice

        do {
            try gitTask.run()
            // Read before waitUntilExit to avoid deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            gitTask.waitUntilExit()

            if gitTask.terminationStatus == 0 {
                let gitRoot = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if !gitRoot.isEmpty {
                    let projectName = URL(fileURLWithPath: gitRoot).lastPathComponent

                    // If cwd is different from git root, show subdirectory
                    if cwd != gitRoot {
                        let relativePath = cwd.replacingOccurrences(of: gitRoot + "/", with: "")
                        return "\(projectName)/\(relativePath)"
                    }
                    return projectName
                }
            }
        } catch {
            // Fall through to fallback
        }

        // Fallback: use folder name
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    func getPyCharmProjectForPath(_ cwd: String) -> String? {
        // Get PyCharm window titles via AppleScript
        let script = """
            tell application "System Events"
                tell process "pycharm"
                    set windowNames to name of every window
                    set output to ""
                    repeat with wName in windowNames
                        set output to output & wName & "|||"
                    end repeat
                    return output
                end tell
            end tell
            """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script),
              let result = appleScript.executeAndReturnError(&error).stringValue else {
            return nil
        }

        // Parse window names (format: "projectname – filename")
        let windowNames = result.components(separatedBy: "|||").filter { !$0.isEmpty }
        let cwdComponents = cwd.lowercased().components(separatedBy: "/")

        for windowName in windowNames {
            // Extract project name (before " – ")
            let projectName = windowName.components(separatedBy: " – ").first?.trimmingCharacters(in: .whitespaces) ?? windowName

            // Check if cwd contains this project name
            if cwdComponents.contains(projectName.lowercased()) {
                return projectName
            }
        }

        return nil
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
            // Read data BEFORE waitUntilExit to avoid pipe buffer deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

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
                            let ttyName = getProcessTty(pid: pid)
                            let weztermPane = getWeztermPane(pid: pid)
                            processes.append(ClaudeProcess(pid: pid, cwd: cwd, terminal: terminal, ttyName: ttyName, weztermPane: weztermPane))
                            NSLog("Found Claude process: PID=\(pid), cwd=\(cwd), terminal=\(terminal)")
                        } else {
                            NSLog("Could not get cwd for PID \(pid)")
                        }
                    }
                }
            }
        } catch {
            NSLog("Error finding Claude processes: \(error)")
        }

        NSLog("findClaudeProcesses: found \(processes.count) processes")
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
            // Read before waitUntilExit to avoid deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
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

    func getProcessTty(pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "tty="]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            // Read before waitUntilExit to avoid deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            let tty = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !tty.isEmpty && tty != "??" {
                return tty
            }
        } catch {
            // Ignore
        }
        return nil
    }

    func getWeztermPane(pid: Int32) -> String? {
        // Check if this is a WezTerm process by walking up the tree
        var currentPid = pid
        var isWezTerm = false

        for _ in 0..<10 {
            guard let ppid = getParentPid(currentPid), ppid > 1 else { break }
            if let appName = getAppNameFromPid(ppid), appName == "WezTerm" {
                isWezTerm = true
                break
            }
            currentPid = ppid
        }

        if !isWezTerm {
            return nil
        }

        // Get WezTerm pane list and find matching TTY
        let tty = getProcessTty(pid: pid)
        guard let tty = tty else { return nil }

        let weztermPaths = ["/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm"]
        var weztermPath = ""
        for path in weztermPaths {
            if FileManager.default.fileExists(atPath: path) {
                weztermPath = path
                break
            }
        }

        guard !weztermPath.isEmpty else { return nil }

        let script = """
            do shell script "\(weztermPath) cli list --format json"
            """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script),
              let result = appleScript.executeAndReturnError(&error).stringValue,
              let data = result.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        // Find pane with matching TTY
        for pane in panes {
            if let ttyName = pane["tty_name"] as? String {
                if ttyName.contains(tty) {
                    if let paneId = pane["pane_id"] as? Int {
                        return String(paneId)
                    }
                }
            }
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
            // Read before waitUntilExit to avoid deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

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
            // Read before waitUntilExit to avoid deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

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

        // Special handling for WezTerm - use stored pane ID if available
        if appName == "WezTerm" {
            if let paneId = session.weztermPane, !paneId.isEmpty {
                activateWezTermPaneById(paneId: paneId)
            } else {
                activateWezTermPane(workingDirectory: session.workingDirectory)
            }
            return
        }

        // Special handling for Terminal.app - use stored TTY if available
        if appName.hasPrefix("Terminal") {
            if let tty = session.ttyName, !tty.isEmpty {
                activateTerminalByTty(tty: tty)
            } else if let pid = session.pid {
                activateTerminalTab(pid: pid, workingDirectory: session.workingDirectory)
            } else {
                activateApp("Terminal")
            }
            return
        }

        // Special handling for PyCharm - use stored window name if available
        if appName == "PyCharm" {
            if let windowName = session.pycharmWindow, !windowName.isEmpty {
                activatePyCharmWindowByName(windowName: windowName)
            } else {
                activatePyCharmWindow(projectName: session.projectName, workingDirectory: session.workingDirectory)
            }
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

    func activateWezTermPaneById(paneId: String) {
        let weztermPaths = ["/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm"]
        var weztermPath = ""
        for path in weztermPaths {
            if FileManager.default.fileExists(atPath: path) {
                weztermPath = path
                break
            }
        }

        guard !weztermPath.isEmpty else {
            activateApp("WezTerm")
            return
        }

        let script = """
            do shell script "\(weztermPath) cli activate-pane --pane-id \(paneId)"
            tell application "WezTerm" to activate
            """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }

    func activateTerminalByTty(tty: String) {
        let script = """
            tell application "Terminal"
                activate
                set targetTTY to "/dev/\(tty)"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if tty of t is targetTTY then
                                set selected of t to true
                                set frontmost of w to true
                                return
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }

    func activatePyCharmWindowByName(windowName: String) {
        let script = """
            tell application "System Events"
                tell process "pycharm"
                    repeat with w in windows
                        set wName to name of w as text
                        if wName contains "\(windowName)" then
                            tell application "PyCharm" to activate
                            perform action "AXRaise" of w
                            return
                        end if
                    end repeat
                end tell
            end tell
            tell application "PyCharm" to activate
            """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }

    func activatePyCharmWindow(projectName: String, workingDirectory: String) {
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

            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script),
               let result = appleScript.executeAndReturnError(&error).stringValue,
               result == "found" {
                return
            }
        }

        // Fallback: just activate PyCharm
        activateApp("PyCharm")
    }

    func activateTerminalTab(pid: Int32, workingDirectory: String) {
        // Get TTY via shell (more reliable)
        let ttyScript = """
            do shell script "ps -p \(pid) -o tty= | tr -d ' '"
            """
        var ttyError: NSDictionary?
        let tty = NSAppleScript(source: ttyScript)?.executeAndReturnError(&ttyError).stringValue ?? ""

        // Activate Terminal tab by TTY
        let script = """
            tell application "Terminal"
                activate
                if "\(tty)" is not "" and "\(tty)" is not "??" then
                    set targetTTY to "/dev/\(tty)"
                    repeat with w in windows
                        repeat with t in tabs of w
                            try
                                if tty of t is targetTTY then
                                    set selected of t to true
                                    set frontmost of w to true
                                    return "found"
                                end if
                            end try
                        end repeat
                    end repeat
                end if
            end tell
            """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }

    func activateWezTermPane(workingDirectory: String) {
        // Find wezterm binary (check common locations)
        let weztermPaths = [
            "/opt/homebrew/bin/wezterm",
            "/usr/local/bin/wezterm",
            "/Applications/WezTerm.app/Contents/MacOS/wezterm"
        ]

        var weztermPath = ""
        for path in weztermPaths {
            if FileManager.default.fileExists(atPath: path) {
                weztermPath = path
                break
            }
        }

        guard !weztermPath.isEmpty else {
            activateApp("WezTerm")
            return
        }

        // Get pane list
        let script = """
            do shell script "\(weztermPath) cli list --format json"
            """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script),
              let result = appleScript.executeAndReturnError(&error).stringValue,
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
                        let activateScript = """
                            do shell script "\(weztermPath) cli activate-pane --pane-id \(paneId)"
                            tell application "WezTerm" to activate
                            """
                        var activateError: NSDictionary?
                        if let s = NSAppleScript(source: activateScript) {
                            s.executeAndReturnError(&activateError)
                        }
                        return
                    }
                }
            }
        }

        activateApp("WezTerm")
    }

    func activateApp(_ appName: String) {
        let script = """
            tell application "\(appName)" to activate
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

    // MARK: - Per-Session Settings

    func setSessionNotificationOverride(id: String, enabled: Bool?) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].notificationOverride = enabled
            saveSessions()
            onSessionsChanged?()
        }
    }

    func setSessionSoundOverride(id: String, enabled: Bool?) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].soundOverride = enabled
            saveSessions()
            onSessionsChanged?()
        }
    }

    func setSessionVoiceOverride(id: String, enabled: Bool?) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].voiceOverride = enabled
            saveSessions()
            onSessionsChanged?()
        }
    }

    func setSessionReminderOverride(id: String, enabled: Bool?) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].reminderOverride = enabled
            saveSessions()
            onSessionsChanged?()
        }
    }

    func getEffectiveNotification(for session: ClaudeSession) -> Bool {
        let group = session.groupId.flatMap { gid in groups.first { $0.id == gid } }
        return session.notificationOverride ?? group?.notificationOverride ?? notificationEnabled
    }

    func getEffectiveSound(for session: ClaudeSession) -> Bool {
        let group = session.groupId.flatMap { gid in groups.first { $0.id == gid } }
        return session.soundOverride ?? group?.soundOverride ?? soundEnabled
    }

    func getEffectiveVoice(for session: ClaudeSession) -> Bool {
        let group = session.groupId.flatMap { gid in groups.first { $0.id == gid } }
        return session.voiceOverride ?? group?.voiceOverride ?? voiceEnabled
    }

    func getEffectiveReminder(for session: ClaudeSession) -> Bool {
        let group = session.groupId.flatMap { gid in groups.first { $0.id == gid } }
        return session.reminderOverride ?? group?.reminderOverride ?? reminderEnabled
    }

    func setSessionGroup(sessionId: String, groupId: String?) {
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[index].groupId = groupId
            // Assign order at the end of the group
            if let gid = groupId {
                let maxOrder = sessions.filter { $0.groupId == gid }.map { $0.orderInGroup }.max() ?? -1
                sessions[index].orderInGroup = maxOrder + 1
            } else {
                sessions[index].orderInGroup = 0
            }
            saveSessions()
            onSessionsChanged?()
        }
    }

    func reorderSessionInGroup(sessionId: String, beforeSessionId: String?) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let session = sessions[sessionIndex]
        guard let groupId = session.groupId else { return }

        // Get all sessions in this group, sorted by current order
        var groupSessions = sessions.filter { $0.groupId == groupId && $0.status == .running }
            .sorted { $0.orderInGroup < $1.orderInGroup }

        // Remove the session being moved
        groupSessions.removeAll { $0.id == sessionId }

        // Find insert position
        if let beforeId = beforeSessionId,
           let insertIndex = groupSessions.firstIndex(where: { $0.id == beforeId }) {
            groupSessions.insert(session, at: insertIndex)
        } else {
            // Insert at end
            groupSessions.append(session)
        }

        // Update orders for all sessions in group
        for (order, groupSession) in groupSessions.enumerated() {
            if let idx = sessions.firstIndex(where: { $0.id == groupSession.id }) {
                sessions[idx].orderInGroup = order
            }
        }

        saveSessions()
        onSessionsChanged?()
    }

    // MARK: - Group Management

    func createGroup(name: String, colorHex: String) -> SessionGroup {
        let order = (groups.map { $0.order }.max() ?? -1) + 1
        let group = SessionGroup(name: name, colorHex: colorHex, order: order)
        groups.append(group)
        saveGroups()
        onSessionsChanged?()
        return group
    }

    func updateGroup(id: String, name: String? = nil, colorHex: String? = nil, order: Int? = nil) {
        if let index = groups.firstIndex(where: { $0.id == id }) {
            if let name = name { groups[index].name = name }
            if let colorHex = colorHex { groups[index].colorHex = colorHex }
            if let order = order { groups[index].order = order }
            saveGroups()
            onSessionsChanged?()
        }
    }

    func deleteGroup(id: String) {
        // Remove group from sessions
        for i in sessions.indices where sessions[i].groupId == id {
            sessions[i].groupId = nil
        }
        saveSessions()

        groups.removeAll { $0.id == id }
        saveGroups()
        onSessionsChanged?()
    }

    func moveGroupUp(id: String) {
        let sortedGroups = groups.sorted { $0.order < $1.order }
        guard let currentIndex = sortedGroups.firstIndex(where: { $0.id == id }),
              currentIndex > 0 else { return }

        let prevGroup = sortedGroups[currentIndex - 1]
        let currentGroup = sortedGroups[currentIndex]

        // Swap orders
        if let prevIdx = groups.firstIndex(where: { $0.id == prevGroup.id }),
           let currIdx = groups.firstIndex(where: { $0.id == currentGroup.id }) {
            let tempOrder = groups[prevIdx].order
            groups[prevIdx].order = groups[currIdx].order
            groups[currIdx].order = tempOrder
        }

        saveGroups()
        onSessionsChanged?()
    }

    func moveGroupDown(id: String) {
        let sortedGroups = groups.sorted { $0.order < $1.order }
        guard let currentIndex = sortedGroups.firstIndex(where: { $0.id == id }),
              currentIndex < sortedGroups.count - 1 else { return }

        let nextGroup = sortedGroups[currentIndex + 1]
        let currentGroup = sortedGroups[currentIndex]

        // Swap orders
        if let nextIdx = groups.firstIndex(where: { $0.id == nextGroup.id }),
           let currIdx = groups.firstIndex(where: { $0.id == currentGroup.id }) {
            let tempOrder = groups[nextIdx].order
            groups[nextIdx].order = groups[currIdx].order
            groups[currIdx].order = tempOrder
        }

        saveGroups()
        onSessionsChanged?()
    }

    func setGroupNotificationOverride(id: String, enabled: Bool?) {
        if let index = groups.firstIndex(where: { $0.id == id }) {
            groups[index].notificationOverride = enabled
            saveGroups()
            onSessionsChanged?()
        }
    }

    func setGroupSoundOverride(id: String, enabled: Bool?) {
        if let index = groups.firstIndex(where: { $0.id == id }) {
            groups[index].soundOverride = enabled
            saveGroups()
            onSessionsChanged?()
        }
    }

    func setGroupVoiceOverride(id: String, enabled: Bool?) {
        if let index = groups.firstIndex(where: { $0.id == id }) {
            groups[index].voiceOverride = enabled
            saveGroups()
            onSessionsChanged?()
        }
    }

    func setGroupReminderOverride(id: String, enabled: Bool?) {
        if let index = groups.firstIndex(where: { $0.id == id }) {
            groups[index].reminderOverride = enabled
            saveGroups()
            onSessionsChanged?()
        }
    }

    func getGroupedSessions() -> [(group: SessionGroup?, sessions: [ClaudeSession])] {
        // Sort groups by order
        let sortedGroups = groups.sorted { $0.order < $1.order }

        var result: [(group: SessionGroup?, sessions: [ClaudeSession])] = []

        // Add grouped sessions first
        for group in sortedGroups {
            let groupSessions = sessions.filter { $0.groupId == group.id }
            if !groupSessions.isEmpty {
                result.append((group: group, sessions: groupSessions))
            }
        }

        // Add ungrouped sessions
        let ungroupedSessions = sessions.filter { $0.groupId == nil }
        if !ungroupedSessions.isEmpty {
            result.append((group: nil, sessions: ungroupedSessions))
        }

        return result
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

    static let notificationCategoryId = "SESSION_COMPLETED"
    static let showActionId = "SHOW_SESSION"

    func registerNotificationCategories() {
        let showAction = UNNotificationAction(
            identifier: SessionManager.showActionId,
            title: "Show",
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: SessionManager.notificationCategoryId,
            actions: [showAction],
            intentIdentifiers: [],
            options: [.customDismissAction]  // Enable dismiss action callback
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func sendCompletionNotification(for session: ClaudeSession) {
        // Priority: session > group > global
        let group = session.groupId.flatMap { gid in groups.first { $0.id == gid } }

        let shouldNotify = session.notificationOverride ?? group?.notificationOverride ?? notificationEnabled
        let shouldSound = session.soundOverride ?? group?.soundOverride ?? soundEnabled
        let shouldVoice = session.voiceOverride ?? group?.voiceOverride ?? voiceEnabled
        let shouldRemind = session.reminderOverride ?? group?.reminderOverride ?? reminderEnabled

        // Record when alert was triggered for this session
        let triggerTime = Date()
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].alertTriggeredAt = triggerTime
            sessions[index].remindersSent = 0
            saveSessions()
        }

        // Send macOS notification if enabled
        if shouldNotify {
            let content = UNMutableNotificationContent()
            content.title = "Claude Task Completed"
            content.body = "\(session.terminalInfo) · \(session.projectName)"
            content.sound = nil  // We handle sound separately
            content.userInfo = ["sessionId": session.id]
            content.categoryIdentifier = SessionManager.notificationCategoryId

            let request = UNNotificationRequest(
                identifier: session.id,
                content: content,
                trigger: nil
            )

            NSLog("Sending notification for session: \(session.projectName), alertTriggeredAt: \(triggerTime)")
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    NSLog("Failed to deliver notification: \(error)")
                } else {
                    NSLog("Notification scheduled successfully for: \(session.projectName)")
                }
            }

            // Schedule reminders if enabled
            if shouldRemind {
                scheduleReminders(for: session, triggeredAt: triggerTime)
            }
        }

        // Play sound if enabled
        if shouldSound {
            playAlertSound()
        }

        // Speak if enabled
        if shouldVoice {
            speakSummary(session)
        }
    }

    func scheduleReminders(for session: ClaudeSession, triggeredAt: Date) {
        let content = UNMutableNotificationContent()
        content.title = "Reminder: Task Completed"
        content.body = "\(session.terminalInfo) · \(session.projectName)"
        content.sound = .default
        content.userInfo = ["sessionId": session.id, "isReminder": true, "triggeredAt": triggeredAt.timeIntervalSince1970]
        content.categoryIdentifier = SessionManager.notificationCategoryId

        NSLog("Scheduling reminders for session \(session.id), triggered at: \(triggeredAt)")

        if reminderCount == 0 {
            // Infinite: use repeating trigger
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: TimeInterval(reminderInterval),
                repeats: true
            )

            let request = UNNotificationRequest(
                identifier: "\(session.id)-reminder-infinite",
                content: content,
                trigger: trigger
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    NSLog("Failed to schedule infinite reminder: \(error)")
                } else {
                    NSLog("Infinite reminder scheduled every \(self.reminderInterval)s for session \(session.id)")
                }
            }
        } else {
            // Finite: schedule specific number of reminders at intervals from trigger time
            for i in 1...reminderCount {
                // Calculate when this reminder should fire based on original trigger time
                let reminderTime = triggeredAt.addingTimeInterval(TimeInterval(reminderInterval * i))
                let now = Date()

                // Only schedule if the reminder time is in the future
                let timeUntilReminder = reminderTime.timeIntervalSince(now)
                if timeUntilReminder > 0 {
                    let trigger = UNTimeIntervalNotificationTrigger(
                        timeInterval: timeUntilReminder,
                        repeats: false
                    )

                    let request = UNNotificationRequest(
                        identifier: "\(session.id)-reminder-\(i)",
                        content: content,
                        trigger: trigger
                    )

                    UNUserNotificationCenter.current().add(request) { [weak self] error in
                        if let error = error {
                            NSLog("Failed to schedule reminder \(i): \(error)")
                        } else {
                            NSLog("Reminder \(i) for session \(session.id) scheduled at \(reminderTime) (in \(timeUntilReminder)s)")
                            // Track that reminder was scheduled
                            if let self = self, let index = self.sessions.firstIndex(where: { $0.id == session.id }) {
                                self.sessions[index].remindersSent = i
                                self.saveSessions()
                            }
                        }
                    }
                } else {
                    NSLog("Skipping reminder \(i) for session \(session.id) - time already passed")
                }
            }
        }
    }

    /// Re-schedule reminders for sessions that were persisted (e.g., after app restart)
    func restoreReminders() {
        for session in sessions where session.status == .completed {
            guard let triggeredAt = session.alertTriggeredAt else { continue }

            // Check if reminders should be enabled for this session
            let group = session.groupId.flatMap { gid in groups.first { $0.id == gid } }
            let shouldRemind = session.reminderOverride ?? group?.reminderOverride ?? reminderEnabled

            if shouldRemind {
                NSLog("Restoring reminders for session \(session.id), originally triggered at \(triggeredAt)")
                scheduleReminders(for: session, triggeredAt: triggeredAt)
            }
        }
    }

    func cancelReminders(for sessionId: String) {
        // Cancel infinite reminder
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["\(sessionId)-reminder-infinite"])

        // Cancel finite reminders (use a reasonable max to cover all cases)
        var identifiers: [String] = []
        let maxCount = max(reminderCount, 10)
        for i in 1...maxCount {
            identifiers.append("\(sessionId)-reminder-\(i)")
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func speakSummary(_ session: ClaudeSession) {
        let textToSpeak = applyPronunciationRules(session.projectName)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        task.arguments = [textToSpeak]
        try? task.run()
    }

    func applyPronunciationRules(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in pronunciationRules {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .caseInsensitive)
        }
        return result
    }

    func addPronunciationRule(pattern: String, pronunciation: String) {
        pronunciationRules[pattern] = pronunciation
    }

    func removePronunciationRule(pattern: String) {
        pronunciationRules.removeValue(forKey: pattern)
    }

    func cancelNotifications(for sessionId: String) {
        // Cancel main notification
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [sessionId])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [sessionId])

        // Cancel reminders
        cancelReminders(for: sessionId)
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

    func saveGroups() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(groups)
            try data.write(to: groupsURL, options: .atomic)
        } catch {
            print("Failed to save groups: \(error)")
        }
    }

    func loadGroups() {
        guard FileManager.default.fileExists(atPath: groupsURL.path) else { return }

        do {
            let data = try Data(contentsOf: groupsURL)
            let decoder = JSONDecoder()
            groups = try decoder.decode([SessionGroup].self, from: data)
        } catch {
            print("Failed to load groups: \(error)")
        }
    }

    // MARK: - Settings

    struct BeaconSettings: Codable {
        var notificationEnabled: Bool
        var soundEnabled: Bool
        var voiceEnabled: Bool
        var maxRecentSessions: Int
        var reminderEnabled: Bool
        var reminderInterval: Int
        var reminderCount: Int
        var pronunciationRules: [String: String]

        // Custom decoder to handle missing keys with defaults
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            notificationEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationEnabled) ?? true
            soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
            voiceEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceEnabled) ?? true
            maxRecentSessions = try container.decodeIfPresent(Int.self, forKey: .maxRecentSessions) ?? 10
            reminderEnabled = try container.decodeIfPresent(Bool.self, forKey: .reminderEnabled) ?? false
            reminderInterval = try container.decodeIfPresent(Int.self, forKey: .reminderInterval) ?? 60
            reminderCount = try container.decodeIfPresent(Int.self, forKey: .reminderCount) ?? 3
            pronunciationRules = try container.decodeIfPresent([String: String].self, forKey: .pronunciationRules) ?? [:]
        }

        init(notificationEnabled: Bool, soundEnabled: Bool, voiceEnabled: Bool, maxRecentSessions: Int, reminderEnabled: Bool, reminderInterval: Int, reminderCount: Int, pronunciationRules: [String: String]) {
            self.notificationEnabled = notificationEnabled
            self.soundEnabled = soundEnabled
            self.voiceEnabled = voiceEnabled
            self.maxRecentSessions = maxRecentSessions
            self.reminderEnabled = reminderEnabled
            self.reminderInterval = reminderInterval
            self.reminderCount = reminderCount
            self.pronunciationRules = pronunciationRules
        }
    }

    func saveSettings() {
        do {
            let settings = BeaconSettings(
                notificationEnabled: notificationEnabled,
                soundEnabled: soundEnabled,
                voiceEnabled: voiceEnabled,
                maxRecentSessions: maxRecentSessions,
                reminderEnabled: reminderEnabled,
                reminderInterval: reminderInterval,
                reminderCount: reminderCount,
                pronunciationRules: pronunciationRules
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
            reminderEnabled = settings.reminderEnabled
            reminderInterval = settings.reminderInterval
            reminderCount = settings.reminderCount
            pronunciationRules = settings.pronunciationRules
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

