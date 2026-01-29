import Foundation

/// Watches Claude Code's state files for session activity.
/// This provides passive detection without requiring hooks or process polling.
///
/// Claude stores session data in:
/// - ~/.claude/projects/<project>/sessions-index.json
/// - ~/.claude/.session-stats.json
///
/// When these files are modified, we can detect session activity.
public class ClaudeStateWatcher {
    public static let shared = ClaudeStateWatcher()

    private var fileDescriptor: CInt = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var directoryWatcher: DirectoryWatcher?

    private let claudeDir: URL
    private let projectsDir: URL

    // Callback for session events
    public var onSessionDetected: ((ClaudeSessionInfo) -> Void)?
    public var onSessionModified: ((ClaudeSessionInfo) -> Void)?

    // Track known sessions to detect new ones
    private var knownSessions: Set<String> = []
    private var lastModifiedTimes: [String: Date] = [:]

    public struct ClaudeSessionInfo {
        public let sessionId: String
        public let projectPath: String
        public let projectName: String
        public let created: Date
        public let modified: Date
        public let summary: String?
        public let messageCount: Int
    }

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        claudeDir = homeDir.appendingPathComponent(".claude")
        projectsDir = claudeDir.appendingPathComponent("projects")

        NSLog("ClaudeStateWatcher: Monitoring \(projectsDir.path)")
    }

    /// Start watching Claude's state files
    public func startWatching() {
        // Initial scan to populate known sessions
        scanAllProjects()

        // Watch the projects directory for changes
        startDirectoryWatch()
    }

    /// Stop watching
    public func stopWatching() {
        directoryWatcher?.stop()
        directoryWatcher = nil
    }

    // MARK: - Directory Watching

    private func startDirectoryWatch() {
        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            NSLog("ClaudeStateWatcher: Projects directory doesn't exist yet, will retry later")
            // Retry after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.startDirectoryWatch()
            }
            return
        }

        directoryWatcher = DirectoryWatcher(url: projectsDir) { [weak self] in
            self?.handleDirectoryChange()
        }
        directoryWatcher?.start()
        NSLog("ClaudeStateWatcher: Started watching \(projectsDir.path)")
    }

    private func handleDirectoryChange() {
        // Debounce rapid changes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.scanAllProjects()
        }
    }

    // MARK: - Session Scanning

    /// Scan all projects for session information
    public func scanAllProjects() {
        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return
        }

        do {
            let projectDirs = try FileManager.default.contentsOfDirectory(
                at: projectsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for projectDir in projectDirs {
                scanProject(at: projectDir)
            }
        } catch {
            NSLog("ClaudeStateWatcher: Error scanning projects - \(error)")
        }
    }

    private func scanProject(at url: URL) {
        // Look for sessions-index.json in the project's .claude subdirectory
        let claudeSubdir = url.appendingPathComponent(".claude")
        let sessionsIndexPath = claudeSubdir.appendingPathComponent("sessions-index.json")

        // Also check directly in the project directory (older format)
        let altSessionsIndexPath = url.appendingPathComponent("sessions-index.json")

        let indexPath = FileManager.default.fileExists(atPath: sessionsIndexPath.path)
            ? sessionsIndexPath
            : (FileManager.default.fileExists(atPath: altSessionsIndexPath.path) ? altSessionsIndexPath : nil)

        guard let indexPath = indexPath else { return }

        // Check if file was modified
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: indexPath.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return
        }

        let lastModified = lastModifiedTimes[indexPath.path]
        if let lastModified = lastModified, modDate <= lastModified {
            return // No change
        }
        lastModifiedTimes[indexPath.path] = modDate

        // Parse sessions index
        parseSessionsIndex(at: indexPath)
    }

    private func parseSessionsIndex(at url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // sessions-index.json has structure: { version, entries: [...], originalPath }
        if let entries = json["entries"] as? [[String: Any]] {
            for sessionDict in entries {
                processSessionEntry(sessionDict)
            }
        }
        // Fallback: check if it's a plain array
        else if let sessions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for sessionDict in sessions {
                processSessionEntry(sessionDict)
            }
        }
    }

    private func processSessionEntry(_ dict: [String: Any]) {
        guard let sessionId = dict["sessionId"] as? String else { return }

        let projectPath = dict["projectPath"] as? String ?? ""
        let projectName = URL(fileURLWithPath: projectPath).lastPathComponent
        let summary = dict["summary"] as? String

        // Parse dates
        let created = parseISO8601Date(dict["created"] as? String)
        let modified = parseISO8601Date(dict["modified"] as? String)

        // Get message count if available
        let messageCount = dict["messageCount"] as? Int ?? 0

        let sessionInfo = ClaudeSessionInfo(
            sessionId: sessionId,
            projectPath: projectPath,
            projectName: projectName,
            created: created ?? Date(),
            modified: modified ?? Date(),
            summary: summary,
            messageCount: messageCount
        )

        // Check if this is a new session
        if !knownSessions.contains(sessionId) {
            knownSessions.insert(sessionId)
            NSLog("ClaudeStateWatcher: New session detected - \(projectName)")
            onSessionDetected?(sessionInfo)
        } else {
            // Session was modified
            onSessionModified?(sessionInfo)
        }
    }

    private func parseISO8601Date(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}

// MARK: - Directory Watcher Helper

/// Simple FSEvents-based directory watcher
private class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let url: URL
    private let callback: () -> Void

    init(url: URL, callback: @escaping () -> Void) {
        self.url = url
        self.callback = callback
    }

    func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [url.path] as CFArray

        stream = FSEventStreamCreate(
            nil,
            { (_, info, _, _, _, _) in
                guard let info = info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.callback()
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // Latency in seconds
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )

        guard let stream = stream else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global())
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
