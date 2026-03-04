import Foundation
import AppKit
import UserNotifications
import Network

// MARK: - Debug Logging

private let debugLogPath = URL(fileURLWithPath: "/tmp/beacon_debug.log")

private func debugLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logLine = "[\(timestamp)] \(message)\n"
    NSLog(message)
    if let data = logLine.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: debugLogPath.path) {
            if let handle = try? FileHandle(forWritingTo: debugLogPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: debugLogPath)
        }
    }
}

// MARK: - Time Formatting (Slack-style)

private func formatRelativeTime(from date: Date) -> String {
    let now = Date()
    let seconds = Int(now.timeIntervalSince(date))

    if seconds < 60 {
        return "just now"
    }

    let minutes = seconds / 60
    if minutes == 1 {
        return "1 min ago"
    }
    if minutes < 60 {
        return "\(minutes) min ago"
    }

    let hours = minutes / 60
    if hours == 1 {
        return "1 hour ago"
    }
    if hours < 24 {
        return "\(hours) hours ago"
    }

    // For older times, show day + time
    let calendar = Calendar.current
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    let timeStr = formatter.string(from: date)

    if calendar.isDateInYesterday(date) {
        return "yesterday \(timeStr)"
    }

    // Within this week - show day name
    let daysAgo = hours / 24
    if daysAgo < 7 {
        formatter.dateFormat = "EEE h:mm a"  // "Mon 3:45 PM"
        return formatter.string(from: date)
    }

    // Older - show date
    formatter.dateFormat = "MMM d, h:mm a"  // "Jan 15, 3:45 PM"
    return formatter.string(from: date)
}

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
    var isExpanded: Bool  // Whether group is expanded in UI

    // Group-level settings overrides (nil = use global setting)
    var notificationOverride: Bool?
    var soundOverride: Bool?
    var voiceOverride: Bool?

    init(
        id: String = UUID().uuidString,
        name: String,
        colorHex: String = "#808080",
        order: Int = 0,
        isExpanded: Bool = true,
        notificationOverride: Bool? = nil,
        soundOverride: Bool? = nil,
        voiceOverride: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.order = order
        self.isExpanded = isExpanded
        self.notificationOverride = notificationOverride
        self.soundOverride = soundOverride
        self.voiceOverride = voiceOverride
    }

    // Custom decoder for backward compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "#808080"
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        notificationOverride = try container.decodeIfPresent(Bool.self, forKey: .notificationOverride)
        soundOverride = try container.decodeIfPresent(Bool.self, forKey: .soundOverride)
        voiceOverride = try container.decodeIfPresent(Bool.self, forKey: .voiceOverride)
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
    var pycharmTabName: String? // PyCharm terminal tab name (e.g., "로컬 (2)")
    var itermSessionId: String? // iTerm2 session ID for pane navigation
    var cursorWindowId: String?  // Cursor extension window ID for precise matching
    var cursorPort: String?      // Cursor extension HTTP port for focus requests

    // Per-session settings overrides (nil = use global setting)
    var notificationOverride: Bool?
    var soundOverride: Bool?
    var voiceOverride: Bool?

    // Group assignment (nil = ungrouped)
    var groupId: String?

    // Tracking - when alert was first triggered
    var alertTriggeredAt: Date?

    // Manual ordering within group (lower = higher in list)
    var orderInGroup: Int = 0

    // True if session was detected while already running (not tracked from start)
    var detectedMidRun: Bool = false

    // True if completion was triggered by a sub-agent stop hook
    var isSubagentStop: Bool = false

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
        pycharmTabName: String? = nil,
        itermSessionId: String? = nil,
        cursorWindowId: String? = nil,
        cursorPort: String? = nil,
        notificationOverride: Bool? = nil,
        soundOverride: Bool? = nil,
        voiceOverride: Bool? = nil,
        groupId: String? = nil,
        alertTriggeredAt: Date? = nil,
        orderInGroup: Int = 0,
        detectedMidRun: Bool = false,
        isSubagentStop: Bool = false
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
        self.pycharmTabName = pycharmTabName
        self.itermSessionId = itermSessionId
        self.cursorWindowId = cursorWindowId
        self.cursorPort = cursorPort
        self.notificationOverride = notificationOverride
        self.soundOverride = soundOverride
        self.voiceOverride = voiceOverride
        self.groupId = groupId
        self.alertTriggeredAt = alertTriggeredAt
        self.orderInGroup = orderInGroup
        self.detectedMidRun = detectedMidRun
        self.isSubagentStop = isSubagentStop
    }

    // Custom decoder for backward compatibility with older saved data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectName = try container.decode(String.self, forKey: .projectName)
        terminalInfo = try container.decode(String.self, forKey: .terminalInfo)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        status = try container.decode(SessionStatus.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        acknowledgedAt = try container.decodeIfPresent(Date.self, forKey: .acknowledgedAt)
        pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        details = try container.decodeIfPresent(String.self, forKey: .details)
        tag = try container.decodeIfPresent(String.self, forKey: .tag)
        weztermPane = try container.decodeIfPresent(String.self, forKey: .weztermPane)
        ttyName = try container.decodeIfPresent(String.self, forKey: .ttyName)
        pycharmWindow = try container.decodeIfPresent(String.self, forKey: .pycharmWindow)
        pycharmTabName = try container.decodeIfPresent(String.self, forKey: .pycharmTabName)
        itermSessionId = try container.decodeIfPresent(String.self, forKey: .itermSessionId)
        cursorWindowId = try container.decodeIfPresent(String.self, forKey: .cursorWindowId)
        cursorPort = try container.decodeIfPresent(String.self, forKey: .cursorPort)
        notificationOverride = try container.decodeIfPresent(Bool.self, forKey: .notificationOverride)
        soundOverride = try container.decodeIfPresent(Bool.self, forKey: .soundOverride)
        voiceOverride = try container.decodeIfPresent(Bool.self, forKey: .voiceOverride)
        groupId = try container.decodeIfPresent(String.self, forKey: .groupId)
        alertTriggeredAt = try container.decodeIfPresent(Date.self, forKey: .alertTriggeredAt)
        // Fields with defaults for backward compatibility
        orderInGroup = try container.decodeIfPresent(Int.self, forKey: .orderInGroup) ?? 0
        detectedMidRun = try container.decodeIfPresent(Bool.self, forKey: .detectedMidRun) ?? false
        isSubagentStop = try container.decodeIfPresent(Bool.self, forKey: .isSubagentStop) ?? false
    }

    // Display summary with fallback
    var displaySummary: String {
        summary ?? "done"
    }
}

// MARK: - Session Manager

class SessionManager {
    static let shared = SessionManager()

    // App version from Version.swift
    static let appVersion = AppVersion.current
    static let githubRepo = "sendbird-playground/claude-code-beacon"

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
    private var pendingNotifications: [String: DispatchWorkItem] = [:] // workingDirectory -> pending timer
    private let notificationDebounceInterval: TimeInterval = 3.0

    // Settings
    var notificationEnabled: Bool = true {
        didSet { saveSettings() }
    }

    var soundEnabled: Bool = true {
        didSet { saveSettings() }
    }

    var soundVolume: Float = 0.5 {
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

    // Voice pronunciation rules: "pattern" -> "pronunciation"
    var pronunciationRules: [String: String] = [:] {
        didSet { saveSettings() }
    }

    // Voice selection (voice identifier strings)
    var selectedEnglishVoice: String = "" {
        didSet {
            saveSettings()
            // Reset synthesizer to use new voice
            englishSynthesizer = nil
        }
    }
    var selectedKoreanVoice: String = "" {
        didSet {
            saveSettings()
            // Reset synthesizer to use new voice
            koreanSynthesizer = nil
        }
    }

    // Experimental: mute Beacon alerts when Zoom mic is active
    var zoomMuteEnabled: Bool = false {
        didSet { saveSettings() }
    }

    // Flag to skip notifications on first scan after startup (stale sessions)
    private var isFirstScan: Bool = true

    // Auto-update state
    @Published var updateAvailable: Bool = false
    @Published var isUpdating: Bool = false
    var latestVersion: String = ""
    var releaseNotes: String = ""
    var releaseURL: String = ""

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let beaconDir = appSupport.appendingPathComponent("Beacon")
        try? FileManager.default.createDirectory(at: beaconDir, withIntermediateDirectories: true)
        storageURL = beaconDir.appendingPathComponent("sessions.json")
        settingsURL = beaconDir.appendingPathComponent("settings.json")
        groupsURL = beaconDir.appendingPathComponent("groups.json")

        debugLog("SessionManager init starting")

        loadSessions()
        loadGroups()
        loadSettings()
        registerNotificationCategories()
        purgeOrphanedReminderNotifications()
        startHttpServer()

        // Keep hook script in sync with app version
        _ = HookManager.shared.installHooks()

        debugLog("SessionManager init complete - voiceEnabled:\(voiceEnabled) soundEnabled:\(soundEnabled)")

        // Check for updates on startup and schedule hourly checks
        checkForUpdates()
        startUpdateCheckTimer()
    }

    // MARK: - Auto Update

    private var updateCheckTimer: Timer?

    private func startUpdateCheckTimer() {
        // Check for updates every hour (3600 seconds)
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            debugLog("Hourly update check triggered")
            self?.checkForUpdates()
        }
    }

    func checkForUpdates() {
        debugLog("Auto-update: Checking for updates via GitHub API")

        // GitHub API URL for latest release
        let urlString = "https://api.github.com/repos/\(SessionManager.githubRepo)/releases/latest"
        guard let url = URL(string: urlString) else {
            debugLog("Auto-update: Invalid GitHub API URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                debugLog("Auto-update: Network error - \(error.localizedDescription)")
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                debugLog("Auto-update: Invalid response")
                return
            }

            if httpResponse.statusCode == 404 {
                debugLog("Auto-update: No releases found (404)")
                return
            }

            guard httpResponse.statusCode == 200, let data = data else {
                debugLog("Auto-update: HTTP error \(httpResponse.statusCode)")
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tagName = json["tag_name"] as? String,
                   let htmlUrl = json["html_url"] as? String {

                    // Remove 'v' prefix if present (e.g., "v1.0.1" -> "1.0.1")
                    let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                    let body = json["body"] as? String ?? ""

                    debugLog("Auto-update: Current version: \(SessionManager.appVersion), Latest: \(remoteVersion)")

                    let hasUpdate = self.isNewerVersion(remoteVersion, than: SessionManager.appVersion)

                    DispatchQueue.main.async {
                        let wasAvailable = self.updateAvailable
                        self.updateAvailable = hasUpdate
                        self.latestVersion = remoteVersion
                        self.releaseNotes = body
                        self.releaseURL = htmlUrl

                        // Send notification if update newly available
                        if hasUpdate && !wasAvailable {
                            self.sendUpdateNotification(version: remoteVersion)
                        }
                    }
                }
            } catch {
                debugLog("Auto-update: JSON parse error - \(error)")
            }
        }.resume()
    }

    // Compare semantic versions (e.g., "1.0.1" > "1.0.0")
    private func isNewerVersion(_ remote: String, than local: String) -> Bool {
        let remoteComponents = remote.split(separator: ".").compactMap { Int($0) }
        let localComponents = local.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(remoteComponents.count, localComponents.count) {
            let r = i < remoteComponents.count ? remoteComponents[i] : 0
            let l = i < localComponents.count ? localComponents[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }

    private func sendUpdateNotification(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Beacon Update Available"
        content.body = "Version \(version) is available. Open Settings to update."
        content.sound = nil

        // Use a small time trigger to ensure proper icon loading
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)

        let request = UNNotificationRequest(
            identifier: "beacon-update",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                debugLog("Failed to send update notification: \(error)")
            } else {
                debugLog("Update notification sent")
            }
        }
    }

    func openReleasePage() {
        guard !releaseURL.isEmpty, let url = URL(string: releaseURL) else {
            // Fallback to releases page
            if let url = URL(string: "https://github.com/\(SessionManager.githubRepo)/releases") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(url)
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
            if let requestString = String(data: data, encoding: .utf8) {
                debugLog("handleConnection received \(data.count) bytes")
                if let jsonStart = requestString.range(of: "\r\n\r\n")?.upperBound {
                    let jsonString = String(requestString[jsonStart...])
                    debugLog("handleConnection extracted JSON: \(String(jsonString.prefix(200)))")
                    self.handleHookData(jsonString)
                } else {
                    debugLog("handleConnection: no \\r\\n\\r\\n found, trying \\n\\n")
                    if let jsonStart = requestString.range(of: "\n\n")?.upperBound {
                        let jsonString = String(requestString[jsonStart...])
                        debugLog("handleConnection extracted JSON via \\n\\n: \(String(jsonString.prefix(200)))")
                        self.handleHookData(jsonString)
                    } else {
                        debugLog("handleConnection: could not find body separator in request")
                    }
                }
            } else {
                debugLog("handleConnection: could not decode data as UTF-8")
            }

            // Send HTTP 200 response
            let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func handleHookData(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else {
            debugLog("handleHookData: failed to convert string to data")
            return
        }
        // Log full JSON and raw bytes for debugging
        debugLog("handleHookData: raw length=\(jsonString.count) bytes=\(data.count) last10bytes=\(Array(data.suffix(10)))")
        debugLog("handleHookData: full JSON=\(jsonString)")

        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                debugLog("handleHookData: parsed but not a dictionary")
                return
            }
            json = parsed
        } catch {
            debugLog("handleHookData: JSON parse ERROR: \(error)")
            return
        }
        debugLog("handleHookData: parsed JSON with keys: \(json.keys.sorted())")

        let projectName = json["projectName"] as? String ?? "Unknown"
        let terminalInfo = json["terminalInfo"] as? String ?? "Terminal"
        let workingDirectory = json["workingDirectory"] as? String ?? ""
        let summary = json["summary"] as? String
        let details = json["details"] as? String
        let tag = json["tag"] as? String
        let weztermPane = json["weztermPane"] as? String
        var ttyName = json["ttyName"] as? String
        let pycharmWindow = json["pycharmWindow"] as? String
        let pycharmTabName = json["pycharmTabName"] as? String
        let itermSessionId = json["itermSessionId"] as? String
        let cursorWindowId = json["cursorWindowId"] as? String
        let cursorPort = json["cursorPort"] as? String
        let isSubagent = json["isSubagent"] as? String == "true"
        let siblingCount = Int(json["siblingCount"] as? String ?? "0") ?? 0

        // Validate TTY - re-resolve from PID if invalid
        if let tty = ttyName, (tty.isEmpty || tty == "??" || tty.contains("not a tty")) {
            ttyName = nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Find existing running session - prefer TTY match, fall back to working directory
            let index: Int?
            if let validTty = ttyName {
                // Match by TTY first (most precise - handles multiple sessions in same directory)
                index = self.sessions.firstIndex(where: {
                    $0.status == .running && $0.ttyName == validTty
                }) ?? self.sessions.firstIndex(where: {
                    $0.status == .running && $0.workingDirectory == workingDirectory
                })
            } else {
                index = self.sessions.firstIndex(where: {
                    $0.status == .running && $0.workingDirectory == workingDirectory
                })
            }

            if let index = index {
                // Update existing session with hook data and mark completed
                self.sessions[index].summary = summary
                self.sessions[index].details = details
                self.sessions[index].tag = tag
                self.sessions[index].weztermPane = weztermPane
                // Only update ttyName if hook provides a valid one; keep existing if hook's is nil
                if let validTty = ttyName {
                    self.sessions[index].ttyName = validTty
                } else if let existingTty = self.sessions[index].ttyName,
                          (existingTty.isEmpty || existingTty == "??" || existingTty.contains("not a tty")) {
                    // Existing TTY is also invalid - try re-resolving from PID
                    if let pid = self.sessions[index].pid {
                        self.sessions[index].ttyName = self.getProcessTty(pid: pid)
                    }
                }
                self.sessions[index].pycharmWindow = pycharmWindow
                self.sessions[index].pycharmTabName = pycharmTabName
                self.sessions[index].itermSessionId = itermSessionId
                self.sessions[index].cursorWindowId = cursorWindowId
                self.sessions[index].cursorPort = cursorPort
                self.sessions[index].isSubagentStop = isSubagent
                self.sessions[index].status = .completed
                self.sessions[index].completedAt = Date()
                let debounce: TimeInterval = (isSubagent || siblingCount > 0) ? 5.0 : self.notificationDebounceInterval
                self.scheduleNotification(for: self.sessions[index], debounceInterval: debounce)
            } else {
                // Inherit groupId from previous session with same terminal and working directory
                let inheritedGroupId = self.sessions.first(where: {
                    $0.terminalInfo == terminalInfo && $0.workingDirectory == workingDirectory && $0.groupId != nil
                })?.groupId
                    ?? self.sessions.first(where: { $0.workingDirectory == workingDirectory && $0.groupId != nil })?.groupId

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
                    pycharmWindow: pycharmWindow,
                    pycharmTabName: pycharmTabName,
                    itermSessionId: itermSessionId,
                    cursorWindowId: cursorWindowId,
                    cursorPort: cursorPort,
                    groupId: inheritedGroupId,
                    isSubagentStop: isSubagent
                )
                self.sessions.insert(session, at: 0)
                let debounce: TimeInterval = (isSubagent || siblingCount > 0) ? 5.0 : self.notificationDebounceInterval
                self.scheduleNotification(for: session, debounceInterval: debounce)
            }

            self.saveSessions()
            self.trimOldSessions()
            self.onSessionsChanged?()
        }
    }

    func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()

        // Log current authorization status before requesting
        center.getNotificationSettings { settings in
            let statusNames = ["notDetermined", "denied", "authorized", "provisional", "ephemeral"]
            let statusName = settings.authorizationStatus.rawValue < statusNames.count
                ? statusNames[Int(settings.authorizationStatus.rawValue)]
                : "unknown(\(settings.authorizationStatus.rawValue))"
            debugLog("Notification auth status before request: \(statusName)")
            debugLog("Bundle identifier: \(Bundle.main.bundleIdentifier ?? "nil")")
        }

        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            debugLog("Notification permission granted: \(granted)")
            if let error = error {
                debugLog("Notification permission error: \(error)")
            }
            if !granted {
                debugLog("Notifications denied. Enable in System Settings > Notifications > Beacon")
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

    /// Thread-safe snapshot of current sessions. Synchronizes with scanQueue to prevent
    /// data races when the main thread reads while a background scan is modifying sessions.
    func getSessionsSnapshot() -> [ClaudeSession] {
        return scanQueue.sync { self.sessions }
    }

    /// Non-blocking read of last known sessions. May be slightly stale if a scan is
    /// in progress, but avoids blocking the main thread for instant UI display.
    var cachedSessions: [ClaudeSession] {
        return sessions
    }

    func startMonitoring() {
        // Run initial scan synchronously to ensure sessions are detected before UI shows
        scanQueue.sync {
            self.scanForSessions()
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
        // Find session with this PID and remove it silently
        // We don't send notifications on process exit because:
        // 1. User might have pressed Ctrl+C to quit
        // 2. Terminal might have been closed
        // 3. Process might have crashed
        // Notifications should only be sent via hooks when Claude actually completes a task
        if let index = self.sessions.firstIndex(where: { $0.pid == pid && $0.status == .running }) {
            let session = self.sessions[index]
            NSLog("Session removed (process exited, no notification): \(session.projectName)")

            // Just remove the session - don't mark as completed or notify
            self.sessions.remove(at: index)
            self.saveSessions()

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

            // Only skip if there's already a RUNNING session for this PID.
            // Acknowledged/completed sessions should not block new session detection,
            // since Claude processes are long-running and start new tasks with the same PID.
            let hasSessionForPid = sessions.contains(where: { $0.pid == process.pid && $0.status == .running })

            // Fix stale TTY on existing running sessions for this PID
            if hasSessionForPid, let validTty = process.ttyName, !validTty.isEmpty, validTty != "??", !validTty.contains("not a tty") {
                for i in sessions.indices where sessions[i].pid == process.pid && sessions[i].status == .running {
                    if let existingTty = sessions[i].ttyName,
                       (existingTty.isEmpty || existingTty == "??" || existingTty.contains("not a tty")) {
                        sessions[i].ttyName = validTty
                        needsUIUpdate = true
                    }
                }
            }

            if !hasSessionForPid {
                // Truly new PID - create a new session
                knownPids.insert(process.pid)

                // Try to find git root for better project name
                let projectName = getProjectName(for: process.cwd, terminal: process.terminal)

                // Get PyCharm window/tab info if this is a PyCharm session
                var pycharmWindow: String? = nil
                var pycharmTabName: String? = nil
                if process.terminal == "PyCharm" {
                    // Try plugin first for accurate tab info
                    if let pluginInfo = PyCharmIntegration.queryPluginForProject(workingDirectory: process.cwd) {
                        pycharmWindow = pluginInfo.project
                        pycharmTabName = pluginInfo.tabName
                    } else {
                        // Fallback to AppleScript for window name only
                        pycharmWindow = getFrontmostPyCharmWindow()
                    }
                }

                // Get Cursor window info if this is a Cursor session
                var cursorWindowId: String? = nil
                var cursorPort: String? = nil
                if process.terminal == "Cursor" {
                    let processInfo = ProcessInfo(pid: process.pid, workingDirectory: process.cwd, terminalName: process.terminal, ttyName: process.ttyName)
                    let metadata = CursorIntegration.extractMetadata(processInfo: processInfo)
                    cursorWindowId = metadata["cursorWindowId"]
                    cursorPort = metadata["cursorPort"]
                }

                // Inherit groupId from previous session with same terminal and working directory
                let matchingSessions = sessions.filter { $0.terminalInfo == process.terminal && $0.workingDirectory == process.cwd }
                NSLog("Looking for groupId inheritance for terminal: \(process.terminal), cwd: \(process.cwd)")
                NSLog("Found \(matchingSessions.count) matching sessions")
                for s in matchingSessions {
                    NSLog("  - Session \(s.id): groupId=\(s.groupId ?? "nil"), status=\(s.status.rawValue)")
                }
                let inheritedGroupId = matchingSessions.first(where: { $0.groupId != nil })?.groupId
                // Fallback: try matching by working directory only if no terminal+dir match
                    ?? sessions.first(where: { $0.workingDirectory == process.cwd && $0.groupId != nil })?.groupId
                NSLog("Inherited groupId: \(inheritedGroupId ?? "none")")

                let session = ClaudeSession(
                    projectName: projectName,
                    terminalInfo: process.terminal,
                    workingDirectory: process.cwd,
                    status: .running,
                    pid: process.pid,
                    weztermPane: process.weztermPane,
                    ttyName: process.ttyName,
                    pycharmWindow: pycharmWindow,
                    pycharmTabName: pycharmTabName,
                    cursorWindowId: cursorWindowId,
                    cursorPort: cursorPort,
                    groupId: inheritedGroupId,
                    detectedMidRun: true  // Session was already running when detected
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

        // Remove running sessions whose processes have ended
        // We don't send notifications here because process exit could be:
        // - User pressed Ctrl+C
        // - Terminal was closed
        // - Process crashed
        // Notifications should only come from Claude's hook when a task completes
        var indicesToRemove: [Int] = []
        for i in sessions.indices {
            if sessions[i].status == .running, let pid = sessions[i].pid {
                if !runningPids.contains(pid) {
                    NSLog("Removing session (process ended, no notification): \(sessions[i].projectName)")
                    indicesToRemove.append(i)
                    stopProcessExitMonitor(pid: pid)
                }
            }
        }
        // Remove in reverse order to maintain valid indices
        for i in indicesToRemove.reversed() {
            sessions.remove(at: i)
        }
        if !indicesToRemove.isEmpty {
            saveSessions()
            needsUIUpdate = true
        }

        // Mark first scan as complete
        if isFirstScan {
            isFirstScan = false
            NSLog("First scan complete - future session completions will trigger notifications")
        }

        // Clean up PIDs from acknowledged/completed sessions that are no longer running
        // This allows new sessions to be created when a truly new process starts
        for i in sessions.indices.reversed() {
            if let pid = sessions[i].pid,
               (sessions[i].status == .acknowledged || sessions[i].status == .completed),
               !runningPids.contains(pid) {
                // Clear the PID so this session won't block new sessions
                sessions[i].pid = nil
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
        // Dynamically find the PyCharm process name
        let processName = getJetBrainsProcessName() ?? "pycharm"
        let script = """
            tell application "System Events"
                tell process "\(processName)"
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

    /// Get the actual System Events process name for the running JetBrains IDE
    private func getJetBrainsProcessName() -> String? {
        let script = """
            tell application "System Events"
                set processList to name of every process
                repeat with procName in processList
                    if procName contains "pycharm" or procName contains "PyCharm" then
                        return procName as text
                    end if
                end repeat
                repeat with procName in processList
                    if procName contains "jetbrains" or procName contains "JetBrains" then
                        return procName as text
                    end if
                end repeat
            end tell
            return ""
            """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script),
           let result = appleScript.executeAndReturnError(&error).stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !result.isEmpty {
            return result
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
        // Try plugin first — most reliable
        if let pluginInfo = PyCharmIntegration.queryPluginForProject(workingDirectory: cwd) {
            return pluginInfo.project
        }

        // Fallback: Get PyCharm window titles via AppleScript
        let processName = getJetBrainsProcessName() ?? "pycharm"
        let script = """
            tell application "System Events"
                tell process "\(processName)"
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
            if !tty.isEmpty && tty != "??" && !tty.contains("not a tty") {
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
        debugFileLog("acknowledgeSession called for id: \(id)")
        NSLog("acknowledgeSession called for id: \(id)")
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            debugFileLog("acknowledgeSession: found session at index \(index), setting status to acknowledged")
            NSLog("acknowledgeSession: found session at index \(index), setting status to acknowledged")
            sessions[index].status = .acknowledged
            sessions[index].acknowledgedAt = Date()
            saveSessions()
            onSessionsChanged?()
            cancelNotifications(for: id)
            debugFileLog("acknowledgeSession: completed, called cancelNotifications")
            NSLog("acknowledgeSession: completed for id \(id)")
        } else {
            debugFileLog("acknowledgeSession: session not found for id: \(id)")
            NSLog("acknowledgeSession: session not found for id: \(id)")
        }
    }


    private func debugFileLog(_ message: String) {
        let logPath = NSHomeDirectory() + "/beacon_notification_debug.log"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) - \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }

    /// Navigate to session using userInfo from notification (for reminders when session may not exist)
    func navigateFromNotification(userInfo: [AnyHashable: Any]) {
        debugFileLog("navigateFromNotification called with userInfo: \(userInfo)")

        guard let terminalInfo = userInfo["terminalInfo"] as? String else {
            debugFileLog("navigateFromNotification: no terminalInfo in userInfo")
            return
        }

        let workingDirectory = userInfo["workingDirectory"] as? String ?? ""
        let weztermPane = userInfo["weztermPane"] as? String ?? ""
        let ttyName = userInfo["ttyName"] as? String ?? ""

        debugFileLog("navigateFromNotification: terminal=\(terminalInfo), wezterm=\(weztermPane), tty=\(ttyName)")

        // WezTerm
        if terminalInfo == "WezTerm" {
            if !weztermPane.isEmpty {
                activateWezTermPaneById(paneId: weztermPane)
            } else {
                activateWezTermPane(workingDirectory: workingDirectory)
            }
            return
        }

        // Terminal.app
        if terminalInfo.hasPrefix("Terminal") {
            let context = SessionContext(
                id: "",
                projectName: "",
                workingDirectory: workingDirectory,
                terminalInfo: terminalInfo,
                pid: nil,
                ttyName: ttyName.isEmpty ? nil : ttyName
            )
            TerminalAppIntegration.activate(session: context)
            return
        }

        // Cursor
        if terminalInfo == "Cursor" {
            var metadata: [String: String] = [:]
            if let wid = userInfo["cursorWindowId"] as? String, !wid.isEmpty {
                metadata["cursorWindowId"] = wid
            }
            if let port = userInfo["cursorPort"] as? String, !port.isEmpty {
                metadata["cursorPort"] = port
            }
            let context = SessionContext(
                id: "",
                projectName: userInfo["projectName"] as? String ?? "",
                workingDirectory: workingDirectory,
                terminalInfo: terminalInfo,
                pid: nil,
                ttyName: ttyName.isEmpty ? nil : ttyName,
                metadata: metadata
            )
            CursorIntegration.activate(session: context)
            return
        }

        // PyCharm
        if terminalInfo == "PyCharm" {
            let projectName = userInfo["projectName"] as? String ?? ""
            var metadata: [String: String] = [:]
            if let pycharmWindow = userInfo["pycharmWindow"] as? String, !pycharmWindow.isEmpty {
                metadata["pycharmWindow"] = pycharmWindow
            }
            if let pycharmTabName = userInfo["pycharmTabName"] as? String, !pycharmTabName.isEmpty {
                metadata["pycharmTabName"] = pycharmTabName
            }
            let context = SessionContext(
                id: "",
                projectName: projectName,
                workingDirectory: workingDirectory,
                terminalInfo: terminalInfo,
                pid: nil,
                ttyName: ttyName.isEmpty ? nil : ttyName,
                metadata: metadata
            )
            PyCharmIntegration.activate(session: context)
            return
        }

        // iTerm2
        if terminalInfo == "iTerm2" {
            activateApp("iTerm")
            return
        }

        // Generic fallback
        activateApp(terminalInfo)
    }

    func navigateToSession(id: String) {
        debugFileLog("navigateToSession called for id: \(id)")
        NSLog("navigateToSession called for id: \(id)")
        guard let session = sessions.first(where: { $0.id == id }) else {
            debugFileLog("navigateToSession: session not found")
            NSLog("navigateToSession: session not found for id: \(id)")
            return
        }
        debugFileLog("navigateToSession: found session \(session.projectName), terminal: \(session.terminalInfo)")
        NSLog("navigateToSession: found session \(session.projectName), terminal: \(session.terminalInfo)")

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

        // Special handling for Terminal.app - delegate to TerminalAppIntegration
        if appName.hasPrefix("Terminal") {
            let context = SessionContext(
                id: session.id,
                projectName: session.projectName,
                workingDirectory: session.workingDirectory,
                terminalInfo: session.terminalInfo,
                pid: session.pid,
                ttyName: session.ttyName
            )
            TerminalAppIntegration.activate(session: context)
            return
        }

        // Special handling for iTerm2 - use session ID or TTY for pane navigation
        if appName == "iTerm" || appName == "iTerm2" {
            var metadata: [String: String] = [:]
            if let sessionId = session.itermSessionId, !sessionId.isEmpty {
                metadata["itermSessionId"] = sessionId
            }
            let context = SessionContext(
                id: session.id,
                projectName: session.projectName,
                workingDirectory: session.workingDirectory,
                terminalInfo: session.terminalInfo,
                pid: session.pid,
                ttyName: session.ttyName,
                metadata: metadata
            )
            iTerm2Integration.activate(session: context)
            return
        }

        // Special handling for Cursor - delegate to CursorIntegration
        if appName == "Cursor" {
            var metadata: [String: String] = [:]
            if let wid = session.cursorWindowId, !wid.isEmpty {
                metadata["cursorWindowId"] = wid
            }
            if let port = session.cursorPort, !port.isEmpty {
                metadata["cursorPort"] = port
            }
            let context = SessionContext(
                id: session.id,
                projectName: session.projectName,
                workingDirectory: session.workingDirectory,
                terminalInfo: session.terminalInfo,
                pid: session.pid,
                ttyName: session.ttyName,
                metadata: metadata
            )
            CursorIntegration.activate(session: context)
            return
        }

        // Special handling for PyCharm - delegate to PyCharmIntegration
        if appName == "PyCharm" {
            var metadata: [String: String] = [:]
            if let windowName = session.pycharmWindow, !windowName.isEmpty {
                metadata["pycharmWindow"] = windowName
            }
            if let tabName = session.pycharmTabName, !tabName.isEmpty {
                metadata["pycharmTabName"] = tabName
            }
            let context = SessionContext(
                id: session.id,
                projectName: session.projectName,
                workingDirectory: session.workingDirectory,
                terminalInfo: session.terminalInfo,
                pid: session.pid,
                ttyName: session.ttyName,
                metadata: metadata
            )
            PyCharmIntegration.activate(session: context)
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

    func toggleGroupExpanded(id: String) {
        if let index = groups.firstIndex(where: { $0.id == id }) {
            groups[index].isExpanded.toggle()
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

    /// One-time cleanup to remove any leftover reminder notifications from before reminders were removed.
    /// macOS notification center keeps scheduled notifications even after app uninstall/reinstall.
    /// Uses async dispatch to avoid deadlocking the main thread during init.
    private func purgeOrphanedReminderNotifications() {
        let center = UNUserNotificationCenter.current()

        // Nuclear purge: remove ALL pending and delivered notifications.
        // This kills any repeating reminders left over from old versions.
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        NSLog("Purged all pending and delivered notifications")

        // Repeat after a delay to catch any that fire between purge and notification center init
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            center.removeAllPendingNotificationRequests()
            NSLog("Delayed purge: removed all pending notifications again")
        }
    }

    static let notificationCategoryId = "SESSION_COMPLETED"

    func registerNotificationCategories() {
        // No custom actions - clicking notification navigates to app
        let category = UNNotificationCategory(
            identifier: SessionManager.notificationCategoryId,
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]  // Enable dismiss action callback
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // Check if Do Not Disturb / Focus mode is enabled
    private func isDNDEnabled() -> Bool {
        // Method 1: Check Focus mode via assertions file (macOS Monterey+)
        // The data array always exists, but storeAssertionRecords is only
        // non-empty when a Focus mode is actively engaged.
        let assertionsPath = NSHomeDirectory() + "/Library/DoNotDisturb/DB/Assertions.json"
        if FileManager.default.fileExists(atPath: assertionsPath) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: assertionsPath)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let store = json["data"] as? [[String: Any]] {
                for entry in store {
                    if let records = entry["storeAssertionRecords"] as? [[String: Any]], !records.isEmpty {
                        debugLog("DND detected via Assertions.json (active assertion records found)")
                        return true
                    }
                }
            }
        }

        // Method 2: Check ModeConfigurations for active focus
        let modeConfigPath = NSHomeDirectory() + "/Library/DoNotDisturb/DB/ModeConfigurations.json"
        if FileManager.default.fileExists(atPath: modeConfigPath) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: modeConfigPath)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let modeData = json["data"] as? [[String: Any]] {
                for mode in modeData {
                    if let isActive = mode["isActive"] as? Bool, isActive {
                        debugLog("DND detected via ModeConfigurations.json")
                        return true
                    }
                }
            }
        }

        // Method 3: Fallback — use defaults command to check Focus state
        // This catches cases where the JSON files are moved or restructured in newer macOS
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["-currentHost", "read", "com.apple.notificationcenterui", "doNotDisturb"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if let str = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               str == "1" {
                debugLog("DND detected via defaults doNotDisturb key")
                return true
            }
        } catch {}

        return false
    }

    // MARK: - Zoom Meeting Detection (Experimental)

    private func isZoomRunning() -> Bool {
        return !NSRunningApplication.runningApplications(withBundleIdentifier: "us.zoom.xos").isEmpty
    }

    /// Check if Zoom is in a meeting with microphone unmuted.
    /// Returns true if Beacon alerts should be suppressed.
    private func isZoomMicActive() -> Bool {
        guard zoomMuteEnabled, isZoomRunning() else { return false }

        // Use Zoom's menu bar to detect mic mute state.
        // The Meeting menu contains "Mute audio" when unmuted, "Unmute audio" when muted (English).
        // For Korean: "회의" menu contains "오디오 음소거" when unmuted, "오디오 음소거 해제" when muted.
        // Menu bar is accessible even when Zoom is in the background.
        let script = """
            tell application "System Events"
                tell process "zoom.us"
                    try
                        -- Try English menu first
                        if exists menu bar item "Meeting" of menu bar 1 then
                            set menuItems to name of every menu item of menu 1 of menu bar item "Meeting" of menu bar 1
                            set itemText to menuItems as text
                            if itemText contains "Unmute audio" then
                                return "muted"
                            else if itemText contains "Mute audio" then
                                return "unmuted"
                            end if
                        end if
                        -- Try Korean menu
                        if exists menu bar item "회의" of menu bar 1 then
                            set menuItems to name of every menu item of menu 1 of menu bar item "회의" of menu bar 1
                            set itemText to menuItems as text
                            if itemText contains "오디오 음소거 해제" then
                                return "muted"
                            else if itemText contains "오디오 음소거" then
                                return "unmuted"
                            end if
                        end if
                    end try
                end tell
            end tell
            return "unknown"
            """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            debugLog("Zoom mic check result: \(result)")
            switch result {
            case "unmuted":
                return true   // mic is live → suppress alerts
            case "muted":
                return false  // mic is muted → alerts OK
            default:
                // Could not determine state; safe default: suppress if Zoom is running
                debugLog("Zoom mic state unknown, assuming active (safe default)")
                return true
            }
        } catch {
            debugLog("Zoom mic check failed: \(error)")
            return false
        }
    }

    private func scheduleNotification(for session: ClaudeSession, debounceInterval: TimeInterval? = nil) {
        let key = session.workingDirectory
        let interval = debounceInterval ?? notificationDebounceInterval

        // Cancel any existing pending notification for this working directory
        pendingNotifications[key]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.sendCompletionNotification(for: session)
            self.pendingNotifications.removeValue(forKey: key)
        }

        pendingNotifications[key] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    /// Check if the terminal/IDE app for this session is currently the frontmost application.
    /// If the user is already looking at it, we can suppress alerts.
    private func isSessionAppFrontmost(for session: ClaudeSession) -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        let frontName = (frontApp.localizedName ?? "").lowercased()
        let frontBundle = (frontApp.bundleIdentifier ?? "").lowercased()
        let terminal = session.terminalInfo.lowercased()

        // Match terminal name against frontmost app
        if terminal.contains("cursor") {
            return frontBundle.contains("cursor") || frontName.contains("cursor")
        } else if terminal.contains("pycharm") || terminal.contains("jetbrains") {
            return frontBundle.contains("pycharm") || frontBundle.contains("jetbrains") || frontName.contains("pycharm")
        } else if terminal.contains("wezterm") {
            return frontName.contains("wezterm") || frontBundle.contains("wezterm")
        } else if terminal.contains("iterm") {
            return frontName.contains("iterm") || frontBundle.contains("iterm")
        } else if terminal.contains("terminal") {
            return frontBundle.contains("apple_terminal") || frontName == "terminal"
        } else if terminal.contains("code") {
            return frontBundle.contains("vscode") || frontName.contains("visual studio code")
        }
        return frontName.contains(terminal)
    }

    func sendCompletionNotification(for session: ClaudeSession) {
        debugLog("sendCompletionNotification called for: \(session.projectName)")

        // Suppress alert if the user is already looking at the terminal/IDE
        if isSessionAppFrontmost(for: session) {
            debugLog("Skipping alert — \(session.terminalInfo) is frontmost app, user is already looking at it")
            // Still record the alert timestamp so the session shows as completed
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index].alertTriggeredAt = Date()
                saveSessions()
            }
            onSessionsChanged?()
            return
        }

        // Priority: session > group > global
        let group = session.groupId.flatMap { gid in groups.first { $0.id == gid } }

        let shouldNotify = session.notificationOverride ?? group?.notificationOverride ?? notificationEnabled
        let shouldSound = session.soundOverride ?? group?.soundOverride ?? soundEnabled
        let shouldVoice = session.voiceOverride ?? group?.voiceOverride ?? voiceEnabled

        // Check DND/Focus mode
        let dndActive = isDNDEnabled()
        debugLog("DND/Focus mode active: \(dndActive)")

        // Check Zoom meeting mic status (experimental)
        let zoomMicActive = isZoomMicActive()
        if zoomMicActive {
            debugLog("Zoom mic active — suppressing sound/voice alerts")
        }

        debugLog("Settings - notify:\(shouldNotify) sound:\(shouldSound) voice:\(shouldVoice)")
        debugLog("Global settings - soundEnabled:\(soundEnabled) voiceEnabled:\(voiceEnabled)")

        // Record when alert was triggered for this session
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].alertTriggeredAt = Date()
            saveSessions()
        }

        // Send macOS notification if enabled (suppress if DND active)
        if shouldNotify && !dndActive {
            let content = UNMutableNotificationContent()
            content.title = "Claude Task Completed"
            content.body = "\(session.terminalInfo) · \(session.projectName)"
            content.sound = nil  // We handle sound separately
            content.userInfo = ["sessionId": session.id]
            content.categoryIdentifier = SessionManager.notificationCategoryId

            // Use a small time trigger to ensure proper icon loading
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)

            let request = UNNotificationRequest(
                identifier: session.id,
                content: content,
                trigger: trigger
            )

            debugLog("Sending notification for session: \(session.projectName)")
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    debugLog("Failed to deliver notification: \(error)")
                } else {
                    debugLog("Notification scheduled successfully for: \(session.projectName)")
                }
            }
        } else if dndActive {
            debugLog("Notification suppressed due to DND/Focus mode")
        }

        // Play sound if enabled (suppress if DND active or Zoom mic active)
        if shouldSound && !dndActive && !zoomMicActive {
            debugLog("Calling playAlertSound()")
            playAlertSound()
        } else if zoomMicActive {
            debugLog("Sound suppressed due to Zoom mic active")
        } else if dndActive {
            debugLog("Sound suppressed due to DND/Focus mode")
        } else {
            debugLog("Sound disabled, not playing")
        }

        // Speak if enabled (suppress if DND active or Zoom mic active)
        if shouldVoice && !dndActive && !zoomMicActive {
            debugLog("Calling speakSummary for: \(session.projectName)")
            speakSummary(session)
        } else if zoomMicActive {
            debugLog("Voice suppressed due to Zoom mic active")
        } else if dndActive {
            debugLog("Voice suppressed due to DND/Focus mode")
        } else {
            debugLog("Voice disabled, not speaking")
        }
    }

    private var englishSynthesizer: NSSpeechSynthesizer?
    private var koreanSynthesizer: NSSpeechSynthesizer?

    // Check if text contains Korean characters
    private func containsKorean(_ text: String) -> Bool {
        return text.unicodeScalars.contains { scalar in
            // Korean Hangul ranges
            (0xAC00...0xD7A3).contains(scalar.value) ||  // Syllables
            (0x1100...0x11FF).contains(scalar.value) ||  // Jamo
            (0x3130...0x318F).contains(scalar.value)     // Compat Jamo
        }
    }

    // Get available English voices
    func getEnglishVoices() -> [(id: String, name: String)] {
        let voices = NSSpeechSynthesizer.availableVoices
        var result: [(id: String, name: String)] = []
        for voice in voices {
            let voiceId = voice.rawValue.lowercased()
            // Include voices that are English or have common English identifiers
            if voiceId.contains("en_") || voiceId.contains("en-") ||
               voiceId.contains("english") || voiceId.contains("samantha") ||
               voiceId.contains("alex") || voiceId.contains("victoria") ||
               voiceId.contains("daniel") || voiceId.contains("karen") {
                let name = extractVoiceName(voice.rawValue)
                result.append((id: voice.rawValue, name: name))
            }
        }
        // Sort by name, with Samantha first as default
        result.sort { v1, v2 in
            if v1.name.lowercased().contains("samantha") { return true }
            if v2.name.lowercased().contains("samantha") { return false }
            return v1.name < v2.name
        }
        return result
    }

    // Get available Korean voices
    func getKoreanVoices() -> [(id: String, name: String)] {
        let voices = NSSpeechSynthesizer.availableVoices
        var result: [(id: String, name: String)] = []
        for voice in voices {
            let voiceId = voice.rawValue.lowercased()
            if voiceId.contains("korean") || voiceId.contains("yuna") ||
               voiceId.contains("ko_kr") || voiceId.contains("ko-kr") {
                let name = extractVoiceName(voice.rawValue)
                result.append((id: voice.rawValue, name: name))
            }
        }
        // Sort by name, with Yuna first as default
        result.sort { v1, v2 in
            if v1.name.lowercased().contains("yuna") { return true }
            if v2.name.lowercased().contains("yuna") { return false }
            return v1.name < v2.name
        }
        return result
    }

    // Extract readable voice name from identifier with quality indicator
    private func extractVoiceName(_ voiceId: String) -> String {
        // Voice IDs look like "com.apple.voice.compact.en-US.Samantha"
        // or "com.apple.voice.premium.en-US.Samantha"
        let components = voiceId.split(separator: ".")
        guard let lastName = components.last else { return voiceId }

        let name = String(lastName)
        let lowerId = voiceId.lowercased()

        // Add quality indicator to distinguish variants
        if lowerId.contains(".premium.") {
            return "\(name) (Premium)"
        } else if lowerId.contains(".enhanced.") {
            return "\(name) (Enhanced)"
        } else if lowerId.contains(".compact.") {
            return "\(name) (Compact)"
        }
        return name
    }

    // Find the selected or default Korean voice (defaults to Yuna)
    private func findKoreanVoice() -> NSSpeechSynthesizer.VoiceName? {
        // Use selected voice if set
        if !selectedKoreanVoice.isEmpty {
            return NSSpeechSynthesizer.VoiceName(rawValue: selectedKoreanVoice)
        }
        // Otherwise find Yuna or any Korean voice
        let voices = NSSpeechSynthesizer.availableVoices
        // First try to find Yuna
        for voice in voices {
            if voice.rawValue.lowercased().contains("yuna") {
                return voice
            }
        }
        // Fallback to any Korean voice
        for voice in voices {
            let voiceId = voice.rawValue.lowercased()
            if voiceId.contains("korean") || voiceId.contains("ko_kr") || voiceId.contains("ko-kr") {
                return voice
            }
        }
        return nil
    }

    // Find the selected or default English voice (defaults to Samantha)
    private func findEnglishVoice() -> NSSpeechSynthesizer.VoiceName? {
        if !selectedEnglishVoice.isEmpty {
            return NSSpeechSynthesizer.VoiceName(rawValue: selectedEnglishVoice)
        }
        // Default to Samantha
        let voices = NSSpeechSynthesizer.availableVoices
        for voice in voices {
            if voice.rawValue.lowercased().contains("samantha") {
                return voice
            }
        }
        return nil  // nil means use system default
    }

    func speakSummary(_ session: ClaudeSession) {
        // Apply pronunciation rules to project name
        let textToSpeak = applyPronunciationRules(session.projectName)
        debugLog("speakSummary called - projectName: '\(session.projectName)', after rules: '\(textToSpeak)'")

        if textToSpeak.isEmpty {
            debugLog("WARNING: textToSpeak is empty, skipping speech")
            return
        }

        let useKorean = containsKorean(textToSpeak)
        debugLog("Text language detection: useKorean=\(useKorean)")

        // Must run on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                debugLog("ERROR: self is nil in speakSummary async block")
                return
            }

            debugLog("speakSummary async block executing on main thread")

            // Stop any ongoing speech
            self.englishSynthesizer?.stopSpeaking()
            self.koreanSynthesizer?.stopSpeaking()

            let synth: NSSpeechSynthesizer

            if useKorean {
                // Use Korean voice
                if self.koreanSynthesizer == nil {
                    if let koreanVoice = self.findKoreanVoice() {
                        debugLog("Creating Korean synthesizer with voice: \(koreanVoice.rawValue)")
                        self.koreanSynthesizer = NSSpeechSynthesizer(voice: koreanVoice)
                    } else {
                        debugLog("No Korean voice found, using default")
                        self.koreanSynthesizer = NSSpeechSynthesizer()
                    }
                }
                guard let s = self.koreanSynthesizer else {
                    debugLog("ERROR: Failed to create Korean speech synthesizer")
                    return
                }
                synth = s
            } else {
                // Use English voice
                if self.englishSynthesizer == nil {
                    if let englishVoice = self.findEnglishVoice() {
                        debugLog("Creating English synthesizer with voice: \(englishVoice.rawValue)")
                        self.englishSynthesizer = NSSpeechSynthesizer(voice: englishVoice)
                    } else {
                        debugLog("Using default English voice")
                        self.englishSynthesizer = NSSpeechSynthesizer()
                    }
                }
                guard let s = self.englishSynthesizer else {
                    debugLog("ERROR: Failed to create English speech synthesizer")
                    return
                }
                synth = s
            }

            synth.volume = self.soundVolume
            let success = synth.startSpeaking(textToSpeak)
            debugLog("startSpeaking returned: \(success) for text: '\(textToSpeak)' (korean=\(useKorean)), volume: \(self.soundVolume)")
        }
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
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [sessionId])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [sessionId])
    }

    private var alertSound: NSSound?

    func playAlertSound() {
        debugLog("playAlertSound called")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                debugLog("ERROR: self is nil in playAlertSound async block")
                return
            }
            debugLog("playAlertSound async block executing on main thread")
            // Keep reference to sound
            if self.alertSound == nil {
                debugLog("Creating new NSSound for Glass")
                self.alertSound = NSSound(named: "Glass")
            }
            if let sound = self.alertSound {
                sound.stop()
                sound.volume = self.soundVolume
                let success = sound.play()
                debugLog("NSSound.play() returned: \(success), volume: \(self.soundVolume)")
            } else {
                debugLog("ERROR: Failed to load Glass sound")
            }
        }
    }

    func testVoice() {
        debugLog("Testing voice...")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                debugLog("ERROR: self is nil in testVoice")
                return
            }

            // Stop any ongoing speech
            self.englishSynthesizer?.stopSpeaking()
            self.koreanSynthesizer?.stopSpeaking()

            // Use selected English voice (same as speakSummary)
            if self.englishSynthesizer == nil {
                if let englishVoice = self.findEnglishVoice() {
                    debugLog("Creating English synthesizer with voice: \(englishVoice.rawValue)")
                    self.englishSynthesizer = NSSpeechSynthesizer(voice: englishVoice)
                } else {
                    debugLog("Using default English voice")
                    self.englishSynthesizer = NSSpeechSynthesizer()
                }
            }

            let testText = "Task completed"
            debugLog("Speaking test: \(testText)")
            self.englishSynthesizer?.volume = self.soundVolume
            let success = self.englishSynthesizer?.startSpeaking(testText) ?? false
            debugLog("testVoice startSpeaking returned: \(success), volume: \(self.soundVolume)")
        }
    }

    func testAlerts() {
        debugLog("Testing alerts with current settings - notification:\(notificationEnabled) sound:\(soundEnabled) voice:\(voiceEnabled)")

        // Generate a unique test session ID for this test
        let testSessionId = "test-\(UUID().uuidString)"

        // Test notification if enabled
        if notificationEnabled {
            let content = UNMutableNotificationContent()
            content.title = "Beacon Test"
            content.body = "Test alert from Beacon"
            content.sound = nil
            content.userInfo = ["isTest": true, "sessionId": testSessionId]
            content.categoryIdentifier = SessionManager.notificationCategoryId

            // Use a time trigger instead of immediate to ensure proper icon loading
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)

            let request = UNNotificationRequest(
                identifier: testSessionId,
                content: content,
                trigger: trigger
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    debugLog("Test notification failed: \(error)")
                } else {
                    debugLog("Test notification sent successfully")
                }
            }
        }

        // Test sound if enabled
        if soundEnabled {
            playAlertSound()
        }

        // Test voice if enabled
        if voiceEnabled {
            testVoice()
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
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            NSLog("loadSessions: no sessions file found")
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = try decoder.decode([ClaudeSession].self, from: data)

            NSLog("loadSessions: loaded \(sessions.count) sessions")
            for s in sessions {
                NSLog("  - \(s.projectName): groupId=\(s.groupId ?? "nil"), status=\(s.status.rawValue)")
            }

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
        var soundVolume: Float
        var voiceEnabled: Bool
        var maxRecentSessions: Int
        var pronunciationRules: [String: String]
        var selectedEnglishVoice: String
        var selectedKoreanVoice: String
        var zoomMuteEnabled: Bool

        // Custom decoder to handle missing keys with defaults
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            notificationEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationEnabled) ?? true
            soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
            soundVolume = try container.decodeIfPresent(Float.self, forKey: .soundVolume) ?? 0.5
            voiceEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceEnabled) ?? true
            maxRecentSessions = try container.decodeIfPresent(Int.self, forKey: .maxRecentSessions) ?? 10
            pronunciationRules = try container.decodeIfPresent([String: String].self, forKey: .pronunciationRules) ?? [:]
            selectedEnglishVoice = try container.decodeIfPresent(String.self, forKey: .selectedEnglishVoice) ?? ""
            selectedKoreanVoice = try container.decodeIfPresent(String.self, forKey: .selectedKoreanVoice) ?? ""
            zoomMuteEnabled = try container.decodeIfPresent(Bool.self, forKey: .zoomMuteEnabled) ?? false
        }

        init(notificationEnabled: Bool, soundEnabled: Bool, soundVolume: Float, voiceEnabled: Bool, maxRecentSessions: Int, pronunciationRules: [String: String], selectedEnglishVoice: String, selectedKoreanVoice: String, zoomMuteEnabled: Bool) {
            self.notificationEnabled = notificationEnabled
            self.soundEnabled = soundEnabled
            self.soundVolume = soundVolume
            self.voiceEnabled = voiceEnabled
            self.maxRecentSessions = maxRecentSessions
            self.pronunciationRules = pronunciationRules
            self.selectedEnglishVoice = selectedEnglishVoice
            self.selectedKoreanVoice = selectedKoreanVoice
            self.zoomMuteEnabled = zoomMuteEnabled
        }
    }

    func saveSettings() {
        do {
            let settings = BeaconSettings(
                notificationEnabled: notificationEnabled,
                soundEnabled: soundEnabled,
                soundVolume: soundVolume,
                voiceEnabled: voiceEnabled,
                maxRecentSessions: maxRecentSessions,
                pronunciationRules: pronunciationRules,
                selectedEnglishVoice: selectedEnglishVoice,
                selectedKoreanVoice: selectedKoreanVoice,
                zoomMuteEnabled: zoomMuteEnabled
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
            soundVolume = settings.soundVolume
            voiceEnabled = settings.voiceEnabled
            maxRecentSessions = settings.maxRecentSessions
            pronunciationRules = settings.pronunciationRules
            selectedEnglishVoice = settings.selectedEnglishVoice
            selectedKoreanVoice = settings.selectedKoreanVoice
            zoomMuteEnabled = settings.zoomMuteEnabled
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

