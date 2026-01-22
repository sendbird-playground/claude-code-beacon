import Foundation

// MARK: - Models

enum SessionStatus: String, Codable {
    case running = "running"
    case completed = "completed"
    case acknowledged = "acknowledged"
    case snoozed = "snoozed"
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
    var snoozeUntil: Date?
    var reAlarmCount: Int
    var pid: Int32?

    init(
        id: String = UUID().uuidString,
        projectName: String,
        terminalInfo: String,
        workingDirectory: String,
        status: SessionStatus = .running,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        acknowledgedAt: Date? = nil,
        snoozeUntil: Date? = nil,
        reAlarmCount: Int = 0,
        pid: Int32? = nil
    ) {
        self.id = id
        self.projectName = projectName
        self.terminalInfo = terminalInfo
        self.workingDirectory = workingDirectory
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.acknowledgedAt = acknowledgedAt
        self.snoozeUntil = snoozeUntil
        self.reAlarmCount = reAlarmCount
        self.pid = pid
    }

    var needsReAlarm: Bool {
        guard status == .completed else { return false }
        if let snoozeUntil = snoozeUntil, Date() < snoozeUntil {
            return false
        }
        return true
    }
}

// MARK: - Session Manager

class SessionManager {
    static let shared = SessionManager()

    var sessions: [ClaudeSession] = []
    var onSessionsChanged: (() -> Void)?

    private var monitorTimer: Timer?
    private var reAlarmTimer: Timer?
    private let reAlarmInterval: TimeInterval = 60
    private let storageURL: URL

    private var knownPids: Set<Int32> = []

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let beaconDir = appSupport.appendingPathComponent("Beacon")
        try? FileManager.default.createDirectory(at: beaconDir, withIntermediateDirectories: true)
        storageURL = beaconDir.appendingPathComponent("sessions.json")

        loadSessions()
    }

    // MARK: - Monitoring

    func startMonitoring() {
        // Initial scan
        scanForSessions()

        // Monitor every 5 seconds for new/completed sessions
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.scanForSessions()
        }

        // Re-alarm timer
        reAlarmTimer = Timer.scheduledTimer(withTimeInterval: reAlarmInterval, repeats: true) { [weak self] _ in
            self?.checkForReAlarms()
        }
    }

    func scanForSessions() {
        let claudeProcesses = findClaudeProcesses()

        // Check for new processes
        for process in claudeProcesses {
            if !knownPids.contains(process.pid) {
                knownPids.insert(process.pid)

                // Check if we already have a session for this working directory
                if !sessions.contains(where: { $0.workingDirectory == process.cwd && $0.status == .running }) {
                    let session = ClaudeSession(
                        projectName: URL(fileURLWithPath: process.cwd).lastPathComponent,
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
                    onSessionsChanged?()
                }
            }
        }

        // Clean up old PIDs
        knownPids = knownPids.intersection(runningPids)
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
                // Look for claude processes
                if trimmed.contains("claude") || trimmed.contains("Claude") {
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
                // Try to determine terminal app from TTY
                return detectTerminalApp(tty: tty, pid: pid)
            }
        } catch {
            // Ignore
        }

        return "Terminal"
    }

    func detectTerminalApp(tty: String, pid: Int32) -> String {
        // Check environment variables of the process
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "command="]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let cmd = String(data: data, encoding: .utf8)?.lowercased() ?? ""

            if cmd.contains("wezterm") {
                return "WezTerm"
            } else if cmd.contains("iterm") {
                return "iTerm2"
            } else if cmd.contains("cursor") || cmd.contains("vscode") {
                return "Cursor"
            } else if cmd.contains("pycharm") || cmd.contains("jetbrains") {
                return "PyCharm"
            }
        } catch {
            // Ignore
        }

        // Fallback: use TTY suffix
        if let suffix = tty.components(separatedBy: "/").last {
            return "Terminal \(suffix)"
        }

        return "Terminal"
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

    func snoozeSession(id: String, duration: TimeInterval) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].status = .snoozed
            sessions[index].snoozeUntil = Date().addingTimeInterval(duration)
            saveSessions()
            onSessionsChanged?()
            cancelNotifications(for: id)
        }
    }

    func navigateToSession(id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }

        // Activate the appropriate terminal app
        var script = ""

        if session.terminalInfo.contains("WezTerm") {
            script = "tell application \"WezTerm\" to activate"
        } else if session.terminalInfo.contains("iTerm") {
            script = "tell application \"iTerm\" to activate"
        } else if session.terminalInfo.contains("Cursor") {
            script = "tell application \"Cursor\" to activate"
        } else if session.terminalInfo.contains("PyCharm") {
            script = "tell application \"PyCharm\" to activate"
        } else {
            script = "tell application \"Terminal\" to activate"
        }

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

    func clearAcknowledged() {
        sessions.removeAll { $0.status == .acknowledged }
        saveSessions()
        onSessionsChanged?()
    }

    // MARK: - Notifications

    func sendCompletionNotification(for session: ClaudeSession) {
        // Play sound
        playAlertSound()
        print("Task completed: \(session.projectName) - \(session.terminalInfo)")
    }

    func sendReAlarmNotification(for session: ClaudeSession) {
        // Play sound
        playAlertSound()
        print("Reminder: \(session.projectName) - \(session.terminalInfo)")

        // Increment re-alarm count
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].reAlarmCount += 1
            saveSessions()
        }
    }

    func cancelNotifications(for sessionId: String) {
        // No-op without UNUserNotificationCenter
    }

    func playAlertSound() {
        // Play system alert sound
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        task.arguments = ["/System/Library/Sounds/Glass.aiff"]
        try? task.run()
    }

    func checkForReAlarms() {
        for session in sessions {
            // Check if snoozed sessions should wake up
            if session.status == .snoozed, let snoozeUntil = session.snoozeUntil, Date() >= snoozeUntil {
                if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                    sessions[index].status = .completed
                    sessions[index].snoozeUntil = nil
                    saveSessions()
                    onSessionsChanged?()
                }
            }

            // Send re-alarms for completed tasks
            if session.needsReAlarm && session.status == .completed {
                sendReAlarmNotification(for: session)
            }
        }
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
}
