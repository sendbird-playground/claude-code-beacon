import AppKit

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var sessionManager: SessionManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize session manager FIRST
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

        print("Beacon is running in the menu bar")
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
            // Running sessions
            let running = sessions.filter { $0.status == .running }
            if !running.isEmpty {
                let sectionItem = NSMenuItem(title: "🔄 Running (\(running.count))", action: nil, keyEquivalent: "")
                sectionItem.isEnabled = false
                menu.addItem(sectionItem)

                // Track duplicates to add suffixes
                var nameCounts: [String: Int] = [:]
                var nameIndices: [String: Int] = [:]

                // First pass: count occurrences
                for session in running {
                    let key = "\(session.terminalInfo)|\(session.projectName)"
                    nameCounts[key, default: 0] += 1
                }

                // Second pass: create menu items with suffixes for duplicates
                for session in running {
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
                menu.addItem(NSMenuItem.separator())
            }

            // Recent sessions - only show sessions that actually completed (got notifications)
            let recent = sessions.filter { $0.completedAt != nil }
            if !recent.isEmpty {
                let sectionItem = NSMenuItem(title: "📋 Recent (\(recent.count))", action: nil, keyEquivalent: "")
                sectionItem.isEnabled = false
                menu.addItem(sectionItem)

                let maxToShow = sessionManager.maxRecentSessions
                for session in recent.prefix(maxToShow) {
                    let item = createSessionMenuItem(session)
                    menu.addItem(item)
                }

                if recent.count > maxToShow {
                    let moreItem = NSMenuItem(title: "  ... and \(recent.count - maxToShow) more", action: nil, keyEquivalent: "")
                    moreItem.isEnabled = false
                    menu.addItem(moreItem)
                }
                menu.addItem(NSMenuItem.separator())
            }
        }

        // Actions
        menu.addItem(NSMenuItem.separator())

        let clearRecentItem = NSMenuItem(title: "Clear Recent", action: #selector(clearRecent), keyEquivalent: "")
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

        // Max recent sessions submenu
        let maxRecentItem = NSMenuItem(title: "Max Recent Sessions", action: nil, keyEquivalent: "")
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

    func createSessionMenuItem(_ session: ClaudeSession, suffix: String = "") -> NSMenuItem {
        // Show terminal and project name prominently
        let title = "  \(session.terminalInfo) · \(session.projectName)\(suffix)"

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

    @objc func refresh() {
        sessionManager.scanForSessions()
        updateMenu()
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
