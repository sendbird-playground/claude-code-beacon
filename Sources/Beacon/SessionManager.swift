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
        pycharmWindow: String? = nil
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

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let beaconDir = appSupport.appendingPathComponent("Beacon")
        try? FileManager.default.createDirectory(at: beaconDir, withIntermediateDirectories: true)
        storageURL = beaconDir.appendingPathComponent("sessions.json")
        settingsURL = beaconDir.appendingPathComponent("settings.json")

        loadSessions()
        loadSettings()
        requestNotificationPermission()
        startHttpServer()
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
                // Request permission
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    NSLog("Notification permission granted: \(granted)")
                    if let error = error {
                        NSLog("Notification permission error: \(error)")
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
        let claudeProcesses = findClaudeProcesses()
        var needsUIUpdate = false

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
                    // Try to find git root for better project name
                    let projectName = getProjectName(for: process.cwd, terminal: process.terminal)

                    // Get PyCharm window name if this is a PyCharm session
                    var pycharmWindow: String? = nil
                    if process.terminal == "PyCharm" {
                        pycharmWindow = getFrontmostPyCharmWindow()
                    }

                    let session = ClaudeSession(
                        projectName: projectName,
                        terminalInfo: process.terminal,
                        workingDirectory: process.cwd,
                        status: .running,
                        pid: process.pid,
                        weztermPane: process.weztermPane,
                        ttyName: process.ttyName,
                        pycharmWindow: pycharmWindow
                    )
                    sessions.insert(session, at: 0)
                    saveSessions()
                    needsUIUpdate = true

                    // Start monitoring this process for immediate exit notification
                    startProcessExitMonitor(pid: process.pid)
                }
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
            gitTask.waitUntilExit()

            if gitTask.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
                            let ttyName = getProcessTty(pid: pid)
                            let weztermPane = getWeztermPane(pid: pid)
                            processes.append(ClaudeProcess(pid: pid, cwd: cwd, terminal: terminal, ttyName: ttyName, weztermPane: weztermPane))
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

    func getProcessTty(pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "tty="]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
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

            NSLog("Sending notification for session: \(session.projectName)")
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    NSLog("Failed to deliver notification: \(error)")
                } else {
                    NSLog("Notification scheduled successfully for: \(session.projectName)")
                }
            }
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

