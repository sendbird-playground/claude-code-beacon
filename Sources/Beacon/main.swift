import AppKit
import UserNotifications

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var sessionManager: SessionManager!
    var isMenuExpanded: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set notification delegate FIRST
        UNUserNotificationCenter.current().delegate = self

        // Initialize session manager
        sessionManager = SessionManager.shared
        sessionManager.onSessionsChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.updateMenu()
            }
        }

        // Setup menu bar (needs sessionManager to be initialized)
        setupMenuBar()

        // Start monitoring
        sessionManager.startMonitoring()

        NSLog("Beacon is running in the menu bar")
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Show notifications even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        NSLog("Will present notification: \(notification.request.identifier)")
        completionHandler([.banner, .sound, .badge])
    }

    // Handle notification click or action button
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let sessionId = response.notification.request.content.userInfo["sessionId"] as? String {
            // Handle both direct click and "Show" action button
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier ||
               response.actionIdentifier == SessionManager.showActionId {
                NSLog("Notification action for session: \(sessionId), action: \(response.actionIdentifier)")
                sessionManager.navigateToSession(id: sessionId)
                sessionManager.acknowledgeSession(id: sessionId)
            }
        }
        completionHandler()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "Beacon")
            button.image?.isTemplate = true
        }

        updateMenu()
    }

    func updateMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // Header
        let headerItem = NSMenuItem(title: "Beacon - Claude Sessions", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        let sessions = sessionManager.sessions

        if sessions.isEmpty {
            let emptyItem = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            // Sort: running first, then by completedAt descending (most recent first)
            let sorted = sessions.sorted { a, b in
                // Running sessions come first
                if a.status == .running && b.status != .running { return true }
                if a.status != .running && b.status == .running { return false }
                // Both running: sort by createdAt descending
                if a.status == .running && b.status == .running {
                    return a.createdAt > b.createdAt
                }
                // Both completed: sort by completedAt descending
                let aTime = a.completedAt ?? a.createdAt
                let bTime = b.completedAt ?? b.createdAt
                return aTime > bTime
            }

            // Track duplicates to add suffixes
            var nameCounts: [String: Int] = [:]
            var nameIndices: [String: Int] = [:]

            // First pass: count occurrences
            for session in sorted {
                let key = "\(session.terminalInfo)|\(session.projectName)"
                nameCounts[key, default: 0] += 1
            }

            // Second pass: create menu items
            let maxToShow = sessionManager.maxRecentSessions
            let showAll = isMenuExpanded || sorted.count <= maxToShow
            let sessionsToShow = showAll ? sorted : Array(sorted.prefix(maxToShow))

            for session in sessionsToShow {
                let key = "\(session.terminalInfo)|\(session.projectName)"
                let count = nameCounts[key] ?? 1
                var suffix = ""
                if count > 1 {
                    nameIndices[key, default: 0] += 1
                    suffix = " #\(nameIndices[key]!)"
                }
                let item = createSessionMenuItem(session, suffix: suffix)
                menu.addItem(item)
            }

            // Show expand/collapse option
            if sorted.count > maxToShow {
                if isMenuExpanded {
                    let lessItem = NSMenuItem(title: "  ▲ Show less", action: #selector(collapseMenu), keyEquivalent: "")
                    lessItem.target = self
                    lessItem.tag = expandCollapseTag
                    menu.addItem(lessItem)
                } else {
                    let moreItem = NSMenuItem(title: "  ▼ ... and \(sorted.count - maxToShow) more", action: #selector(expandMenu), keyEquivalent: "")
                    moreItem.target = self
                    moreItem.tag = expandCollapseTag
                    menu.addItem(moreItem)
                }
            }
        }

        // Actions
        menu.addItem(NSMenuItem.separator())

        let clearRecentItem = NSMenuItem(title: "Clear Completed", action: #selector(clearRecent), keyEquivalent: "")
        clearRecentItem.target = self
        menu.addItem(clearRecentItem)

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        // Settings submenu
        let settingsItem = NSMenuItem(title: "⚙️ Settings", action: nil, keyEquivalent: "")
        let settingsSubmenu = NSMenu()

        // Alert toggles
        let alertHeader = NSMenuItem(title: "Alerts", action: nil, keyEquivalent: "")
        alertHeader.isEnabled = false
        settingsSubmenu.addItem(alertHeader)

        let notificationItem = NSMenuItem(title: "Notification", action: #selector(toggleNotification), keyEquivalent: "")
        notificationItem.target = self
        notificationItem.state = sessionManager.notificationEnabled ? .on : .off
        settingsSubmenu.addItem(notificationItem)

        let soundItem = NSMenuItem(title: "Sound", action: #selector(toggleSound), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = sessionManager.soundEnabled ? .on : .off
        settingsSubmenu.addItem(soundItem)

        let voiceItem = NSMenuItem(title: "Voice", action: #selector(toggleVoice), keyEquivalent: "")
        voiceItem.target = self
        voiceItem.state = sessionManager.voiceEnabled ? .on : .off
        settingsSubmenu.addItem(voiceItem)

        settingsSubmenu.addItem(NSMenuItem.separator())

        // Notification status and test
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                let status: String
                switch settings.authorizationStatus {
                case .authorized: status = "✓ Enabled"
                case .denied: status = "✗ Disabled"
                case .notDetermined: status = "? Not Set"
                case .provisional: status = "~ Provisional"
                case .ephemeral: status = "○ Ephemeral"
                @unknown default: status = "?"
                }

                let statusItem = NSMenuItem(title: "Notifications: \(status)", action: nil, keyEquivalent: "")
                statusItem.isEnabled = false
                settingsSubmenu.insertItem(statusItem, at: settingsSubmenu.items.count - 1)
            }
        }

        let testNotificationItem = NSMenuItem(title: "Test Notification", action: #selector(testNotification), keyEquivalent: "")
        testNotificationItem.target = self
        settingsSubmenu.addItem(testNotificationItem)

        let openNotificationSettingsItem = NSMenuItem(title: "Open Notification Settings...", action: #selector(openNotificationSettings), keyEquivalent: "")
        openNotificationSettingsItem.target = self
        settingsSubmenu.addItem(openNotificationSettingsItem)

        settingsSubmenu.addItem(NSMenuItem.separator())

        // Max sessions to show submenu
        let maxRecentItem = NSMenuItem(title: "Max Sessions", action: nil, keyEquivalent: "")
        let maxRecentSubmenu = NSMenu()

        for count in [5, 10, 20, 50] {
            let countItem = NSMenuItem(title: "\(count)", action: #selector(setMaxRecent(_:)), keyEquivalent: "")
            countItem.target = self
            countItem.representedObject = count
            if sessionManager.maxRecentSessions == count {
                countItem.state = .on
            }
            maxRecentSubmenu.addItem(countItem)
        }
        maxRecentItem.submenu = maxRecentSubmenu
        settingsSubmenu.addItem(maxRecentItem)

        settingsSubmenu.addItem(NSMenuItem.separator())

        // Reminder settings
        let reminderHeader = NSMenuItem(title: "Reminders", action: nil, keyEquivalent: "")
        reminderHeader.isEnabled = false
        settingsSubmenu.addItem(reminderHeader)

        let reminderEnabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleReminder), keyEquivalent: "")
        reminderEnabledItem.target = self
        reminderEnabledItem.state = sessionManager.reminderEnabled ? .on : .off
        settingsSubmenu.addItem(reminderEnabledItem)

        // Reminder interval submenu
        let reminderIntervalItem = NSMenuItem(title: "Interval", action: nil, keyEquivalent: "")
        let reminderIntervalSubmenu = NSMenu()

        let intervals = [(30, "30 sec"), (60, "1 min"), (120, "2 min"), (300, "5 min")]
        for (seconds, label) in intervals {
            let item = NSMenuItem(title: label, action: #selector(setReminderInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            if sessionManager.reminderInterval == seconds {
                item.state = .on
            }
            reminderIntervalSubmenu.addItem(item)
        }
        reminderIntervalItem.submenu = reminderIntervalSubmenu
        settingsSubmenu.addItem(reminderIntervalItem)

        // Reminder count submenu
        let reminderCountItem = NSMenuItem(title: "Count", action: nil, keyEquivalent: "")
        let reminderCountSubmenu = NSMenu()

        for count in [1, 2, 3, 5, 10] {
            let item = NSMenuItem(title: "\(count)", action: #selector(setReminderCount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = count
            if sessionManager.reminderCount == count {
                item.state = .on
            }
            reminderCountSubmenu.addItem(item)
        }
        reminderCountItem.submenu = reminderCountSubmenu
        settingsSubmenu.addItem(reminderCountItem)

        settingsItem.submenu = settingsSubmenu
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Hook management section
        let hookManager = HookManager.shared
        if hookManager.isHookInstalled {
            let hookStatus = NSMenuItem(title: "✓ Hooks Installed", action: nil, keyEquivalent: "")
            hookStatus.isEnabled = false
            menu.addItem(hookStatus)

            let reinstallItem = NSMenuItem(title: "Reinstall Hooks", action: #selector(reinstallHooks), keyEquivalent: "")
            reinstallItem.target = self
            menu.addItem(reinstallItem)

            let uninstallItem = NSMenuItem(title: "Uninstall Hooks", action: #selector(uninstallHooks), keyEquivalent: "")
            uninstallItem.target = self
            menu.addItem(uninstallItem)
        } else {
            let installItem = NSMenuItem(title: "⚡ Install Hooks (Rich Alerts)", action: #selector(installHooks), keyEquivalent: "")
            installItem.target = self
            menu.addItem(installItem)
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Beacon", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // Update icon badge
        updateIconBadge()
    }

    func formatElapsedTime(_ date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 60 {
            return "\(elapsed)s"
        } else if elapsed < 3600 {
            return "\(elapsed / 60)m"
        } else {
            return "\(elapsed / 3600)h"
        }
    }

    func createSessionMenuItem(_ session: ClaudeSession, suffix: String = "") -> NSMenuItem {
        // Status indicator and time context
        let statusIndicator: String
        let timeContext: String

        switch session.status {
        case .running:
            statusIndicator = "●"
            timeContext = " (\(formatElapsedTime(session.createdAt)))"
        case .completed:
            statusIndicator = "○"
            if let completedAt = session.completedAt {
                timeContext = " (\(formatElapsedTime(completedAt)) ago)"
            } else {
                timeContext = ""
            }
        case .acknowledged:
            statusIndicator = "✓"
            if let completedAt = session.completedAt {
                timeContext = " (\(formatElapsedTime(completedAt)) ago)"
            } else {
                timeContext = ""
            }
        }

        let title = "  \(statusIndicator) \(session.terminalInfo) · \(session.projectName)\(suffix)\(timeContext)"

        // No action on main item - clicking opens submenu, menu stays open
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = session.id

        // Add submenu for actions
        let submenu = NSMenu()

        // Show working directory for context
        let cwdItem = NSMenuItem(title: session.workingDirectory, action: nil, keyEquivalent: "")
        cwdItem.isEnabled = false
        submenu.addItem(cwdItem)
        submenu.addItem(NSMenuItem.separator())

        // Only show "Show" for non-background sessions
        if session.terminalInfo != "Background" {
            let showItem = NSMenuItem(title: "Show", action: #selector(showSession(_:)), keyEquivalent: "")
            showItem.target = self
            showItem.representedObject = session.id
            submenu.addItem(showItem)
        }

        // Show kill option for running sessions
        if session.status == .running {
            let killItem = NSMenuItem(title: "Kill Process", action: #selector(killSession(_:)), keyEquivalent: "")
            killItem.target = self
            killItem.representedObject = session.id
            submenu.addItem(killItem)
        }

        submenu.addItem(NSMenuItem.separator())

        let unlistItem = NSMenuItem(title: "Unlist", action: #selector(removeSession(_:)), keyEquivalent: "")
        unlistItem.target = self
        unlistItem.representedObject = session.id
        submenu.addItem(unlistItem)

        item.submenu = submenu

        return item
    }

    func updateIconBadge() {
        let needsAttention = sessionManager.sessions.filter { $0.status == .completed }.count

        if let button = statusItem.button {
            if needsAttention > 0 {
                button.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "Beacon - \(needsAttention) tasks")
            } else {
                button.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Beacon")
            }
            button.image?.isTemplate = true
        }
    }

    // MARK: - Actions

    @objc func showSession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        sessionManager.navigateToSession(id: sessionId)
        // Only acknowledge completed sessions, not running ones
        if let session = sessionManager.sessions.first(where: { $0.id == sessionId }),
           session.status == .completed {
            sessionManager.acknowledgeSession(id: sessionId)
        }
    }

    @objc func removeSession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        sessionManager.removeSession(id: sessionId)
    }

    @objc func killSession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        sessionManager.killSession(id: sessionId)
    }

    @objc func clearRecent() {
        sessionManager.clearRecent()
    }

    @objc func toggleNotification() {
        sessionManager.notificationEnabled.toggle()
        updateMenu()
    }

    @objc func toggleSound() {
        sessionManager.soundEnabled.toggle()
        updateMenu()
    }

    @objc func toggleVoice() {
        sessionManager.voiceEnabled.toggle()
        updateMenu()
    }

    @objc func setMaxRecent(_ sender: NSMenuItem) {
        guard let count = sender.representedObject as? Int else { return }
        sessionManager.maxRecentSessions = count
        updateMenu()
    }

    @objc func toggleReminder() {
        sessionManager.reminderEnabled.toggle()
        updateMenu()
    }

    @objc func setReminderInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        sessionManager.reminderInterval = seconds
        updateMenu()
    }

    @objc func setReminderCount(_ sender: NSMenuItem) {
        guard let count = sender.representedObject as? Int else { return }
        sessionManager.reminderCount = count
        updateMenu()
    }

    private let expandCollapseTag = 9999
    private let extraSessionTagBase = 10000

    @objc func expandMenu() {
        guard let menu = statusItem.menu else { return }
        isMenuExpanded = true

        // Find the expand/collapse item
        guard let expandItem = menu.item(withTag: expandCollapseTag) else { return }
        let insertIndex = menu.index(of: expandItem)

        // Get sessions to add
        let sessions = sessionManager.sessions
        let sorted = sessions.sorted { a, b in
            if a.status == .running && b.status != .running { return true }
            if a.status != .running && b.status == .running { return false }
            if a.status == .running && b.status == .running {
                return a.createdAt > b.createdAt
            }
            let aTime = a.completedAt ?? a.createdAt
            let bTime = b.completedAt ?? b.createdAt
            return aTime > bTime
        }

        let maxToShow = sessionManager.maxRecentSessions
        let extraSessions = Array(sorted.dropFirst(maxToShow))

        // Insert extra session items before the expand/collapse item
        for (i, session) in extraSessions.enumerated() {
            let item = createSessionMenuItem(session, suffix: "")
            item.tag = extraSessionTagBase + i
            menu.insertItem(item, at: insertIndex + i)
        }

        // Update expand/collapse item to "Show less"
        expandItem.title = "  ▲ Show less"
        expandItem.action = #selector(collapseMenu)
    }

    @objc func collapseMenu() {
        guard let menu = statusItem.menu else { return }
        isMenuExpanded = false

        // Remove extra session items
        var itemsToRemove: [NSMenuItem] = []
        for item in menu.items {
            if item.tag >= extraSessionTagBase {
                itemsToRemove.append(item)
            }
        }
        for item in itemsToRemove {
            menu.removeItem(item)
        }

        // Update expand/collapse item to "Show more"
        if let collapseItem = menu.item(withTag: expandCollapseTag) {
            let sessions = sessionManager.sessions
            let maxToShow = sessionManager.maxRecentSessions
            let remaining = sessions.count - maxToShow
            collapseItem.title = "  ▼ ... and \(remaining) more"
            collapseItem.action = #selector(expandMenu)
        }
    }

    // MARK: - NSMenuDelegate

    func menuDidClose(_ menu: NSMenu) {
        // Reset expanded state when menu closes
        if isMenuExpanded {
            isMenuExpanded = false
            updateMenu()
        }
    }

    @objc func refresh() {
        // Scan must run on scanQueue for thread safety
        sessionManager.triggerScan()
    }

    @objc func testNotification() {
        // Check notification authorization first
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                NSLog("Notification auth status: \(settings.authorizationStatus.rawValue)")
                NSLog("Alert setting: \(settings.alertSetting.rawValue)")

                if settings.authorizationStatus == .denied {
                    self.showAlert(title: "Notifications Disabled",
                                   message: "Please enable notifications for Beacon in:\nSystem Settings → Notifications → Beacon")
                    return
                }

                if settings.authorizationStatus == .notDetermined {
                    // Request permission
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                        DispatchQueue.main.async {
                            if granted {
                                self.sendTestNotification()
                            } else {
                                self.showAlert(title: "Permission Denied",
                                               message: "Notification permission was denied.")
                            }
                        }
                    }
                    return
                }

                self.sendTestNotification()
            }
        }
    }

    func sendTestNotification() {
        // Respect user preferences for test notification
        if sessionManager.notificationEnabled {
            let content = UNMutableNotificationContent()
            content.title = "Beacon Test"
            content.body = "This is a test notification from Beacon."
            content.sound = nil  // We handle sound separately

            let request = UNNotificationRequest(
                identifier: "test-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            NSLog("Sending test notification...")
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    NSLog("Test notification failed: \(error)")
                }
            }
        }

        // Play sound if enabled
        if sessionManager.soundEnabled {
            sessionManager.playAlertSound()
        }

        // Speak if voice enabled
        if sessionManager.voiceEnabled {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            task.arguments = ["Test notification"]
            try? task.run()
        }
    }

    @objc func openNotificationSettings() {
        // Open System Settings -> Notifications -> Beacon
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Hook Management

    @objc func installHooks() {
        let result = HookManager.shared.installHooks()
        showAlert(title: result.success ? "Success" : "Error", message: result.message)
        updateMenu()
    }

    @objc func reinstallHooks() {
        let result = HookManager.shared.installHooks()
        showAlert(title: result.success ? "Success" : "Error", message: result.message)
        updateMenu()
    }

    @objc func uninstallHooks() {
        let result = HookManager.shared.uninstallHooks()
        showAlert(title: result.success ? "Success" : "Error", message: result.message)
        updateMenu()
    }

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = title == "Error" ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Menu bar app, no dock icon
app.run()
