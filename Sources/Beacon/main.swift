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

                for session in running {
                    let item = createSessionMenuItem(session)
                    menu.addItem(item)
                }
                menu.addItem(NSMenuItem.separator())
            }

            // Recent sessions (completed, snoozed, acknowledged - most recent first)
            let recent = sessions.filter { $0.status != .running }
            if !recent.isEmpty {
                let sectionItem = NSMenuItem(title: "📋 Recent (\(recent.count))", action: nil, keyEquivalent: "")
                sectionItem.isEnabled = false
                menu.addItem(sectionItem)

                for session in recent.prefix(10) {
                    let item = createSessionMenuItem(session)
                    menu.addItem(item)
                }

                if recent.count > 10 {
                    let moreItem = NSMenuItem(title: "  ... and \(recent.count - 10) more", action: nil, keyEquivalent: "")
                    moreItem.isEnabled = false
                    menu.addItem(moreItem)
                }
                menu.addItem(NSMenuItem.separator())
            }
        }

        // Actions
        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear Acknowledged", action: #selector(clearAcknowledged), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

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

    func createSessionMenuItem(_ session: ClaudeSession) -> NSMenuItem {
        // Show summary keyword prominently, then project name
        let summaryBadge = session.summary?.uppercased() ?? ""
        let title: String
        if summaryBadge.isEmpty {
            title = "  \(session.projectName) - \(session.terminalInfo)"
        } else {
            title = "  [\(summaryBadge)] \(session.projectName)"
        }

        let item = NSMenuItem(title: title, action: #selector(sessionClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = session.id

        // Add submenu for actions
        let submenu = NSMenu()

        // Show details if available (verbosity level 1)
        if let details = session.details, !details.isEmpty {
            let detailsItem = NSMenuItem(title: "📋 \(details)", action: nil, keyEquivalent: "")
            detailsItem.isEnabled = false
            submenu.addItem(detailsItem)
            submenu.addItem(NSMenuItem.separator())
        }

        // Show terminal info
        let infoItem = NSMenuItem(title: "📍 \(session.terminalInfo)", action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        submenu.addItem(infoItem)

        submenu.addItem(NSMenuItem.separator())

        let goItem = NSMenuItem(title: "Go There", action: #selector(goToSession(_:)), keyEquivalent: "")
        goItem.target = self
        goItem.representedObject = session.id
        submenu.addItem(goItem)

        if session.status == .completed {
            let ackItem = NSMenuItem(title: "Acknowledge", action: #selector(acknowledgeSession(_:)), keyEquivalent: "")
            ackItem.target = self
            ackItem.representedObject = session.id
            submenu.addItem(ackItem)

            submenu.addItem(NSMenuItem.separator())

            let snooze5 = NSMenuItem(title: "Snooze 5 min", action: #selector(snooze5(_:)), keyEquivalent: "")
            snooze5.target = self
            snooze5.representedObject = session.id
            submenu.addItem(snooze5)

            let snooze15 = NSMenuItem(title: "Snooze 15 min", action: #selector(snooze15(_:)), keyEquivalent: "")
            snooze15.target = self
            snooze15.representedObject = session.id
            submenu.addItem(snooze15)

            let snooze60 = NSMenuItem(title: "Snooze 1 hour", action: #selector(snooze60(_:)), keyEquivalent: "")
            snooze60.target = self
            snooze60.representedObject = session.id
            submenu.addItem(snooze60)
        }

        // Speak summary option
        submenu.addItem(NSMenuItem.separator())

        let speakItem = NSMenuItem(title: "🔊 Speak Summary", action: #selector(speakSessionSummary(_:)), keyEquivalent: "")
        speakItem.target = self
        speakItem.representedObject = session.id
        submenu.addItem(speakItem)

        submenu.addItem(NSMenuItem.separator())

        let removeItem = NSMenuItem(title: "Remove", action: #selector(removeSession(_:)), keyEquivalent: "")
        removeItem.target = self
        removeItem.representedObject = session.id
        submenu.addItem(removeItem)

        item.submenu = submenu

        return item
    }

    @objc func speakSessionSummary(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String,
              let session = sessionManager.sessions.first(where: { $0.id == sessionId }) else { return }
        sessionManager.speakSummary(session)
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

    @objc func sessionClicked(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        sessionManager.navigateToSession(id: sessionId)
    }

    @objc func goToSession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        sessionManager.navigateToSession(id: sessionId)
        sessionManager.acknowledgeSession(id: sessionId)
    }

    @objc func acknowledgeSession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        sessionManager.acknowledgeSession(id: sessionId)
    }

    @objc func snooze5(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        sessionManager.snoozeSession(id: sessionId, duration: 5 * 60)
    }

    @objc func snooze15(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        sessionManager.snoozeSession(id: sessionId, duration: 15 * 60)
    }

    @objc func snooze60(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        sessionManager.snoozeSession(id: sessionId, duration: 60 * 60)
    }

    @objc func removeSession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        sessionManager.removeSession(id: sessionId)
    }

    @objc func clearAcknowledged() {
        sessionManager.clearAcknowledged()
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
