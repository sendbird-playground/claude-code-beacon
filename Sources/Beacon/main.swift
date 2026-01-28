import AppKit
import UserNotifications
import SwiftUI

// MARK: - Color Helpers

extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let red = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(rgb & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue, alpha: 1.0)
    }
}

extension Color {
    init?(hex: String) {
        guard let nsColor = NSColor(hex: hex) else { return nil }
        self.init(nsColor: nsColor)
    }
}

// MARK: - SwiftUI Popover View

struct SessionsPopoverView: View {
    @ObservedObject var viewModel: SessionsViewModel
    @State private var draggingGroup: SessionGroup?
    @State private var draggingSession: ClaudeSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Beacon")
                    .font(.headline)
                Spacer()
                Button(action: { viewModel.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                Button(action: { viewModel.openSettings() }) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if viewModel.runningSessions.isEmpty {
                Text("No running sessions")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // All groups (including empty ones for drop targets)
                        ForEach(viewModel.sortedGroups, id: \.id) { group in
                            GroupSectionView(
                                group: group,
                                sessions: viewModel.sessions(for: group),
                                viewModel: viewModel,
                                draggingSession: $draggingSession,
                                draggingGroup: $draggingGroup
                            )
                            .onDrag {
                                draggingGroup = group
                                return NSItemProvider(object: group.id as NSString)
                            }
                        }

                        // Ungrouped sessions
                        if !viewModel.ungroupedSessions.isEmpty {
                            UngroupedSectionView(
                                sessions: viewModel.ungroupedSessions,
                                viewModel: viewModel,
                                draggingSession: $draggingSession
                            )
                            .onDrop(of: [.text], delegate: UngroupedDropDelegate(
                                viewModel: viewModel,
                                draggingSession: $draggingSession
                            ))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 400)
            }

            Divider()

            // Footer
            HStack {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 280)
    }
}

struct GroupSectionView: View {
    let group: SessionGroup
    let sessions: [ClaudeSession]
    @ObservedObject var viewModel: SessionsViewModel
    @Binding var draggingSession: ClaudeSession?
    @Binding var draggingGroup: SessionGroup?
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header - always visible for drag targets
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: group.colorHex) ?? .gray)
                    .frame(width: 8, height: 8)
                Text(group.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                if sessions.isEmpty {
                    Text("Drop here")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isTargeted ? Color.accentColor.opacity(0.2) : Color.clear)

            // Sessions (indented as children)
            ForEach(sessions, id: \.id) { session in
                SessionRowView(session: session, viewModel: viewModel, indented: true)
                    .onDrag {
                        draggingSession = session
                        return NSItemProvider(object: session.id as NSString)
                    }
            }
        }
        .onDrop(of: [.text], delegate: GroupDropDelegate(
            group: group,
            viewModel: viewModel,
            draggingGroup: $draggingGroup,
            draggingSession: $draggingSession,
            isTargeted: $isTargeted
        ))
    }
}

struct UngroupedSectionView: View {
    let sessions: [ClaudeSession]
    @ObservedObject var viewModel: SessionsViewModel
    @Binding var draggingSession: ClaudeSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (only if there are grouped sessions too)
            if viewModel.hasGroupedSessions {
                HStack(spacing: 4) {
                    Circle()
                        .strokeBorder(Color.secondary, lineWidth: 1)
                        .frame(width: 8, height: 8)
                    Text("Ungrouped")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.05))
            }

            ForEach(sessions, id: \.id) { session in
                SessionRowView(session: session, viewModel: viewModel)
                    .onDrag {
                        draggingSession = session
                        return NSItemProvider(object: session.id as NSString)
                    }
            }
        }
    }
}

struct SessionRowView: View {
    let session: ClaudeSession
    @ObservedObject var viewModel: SessionsViewModel
    var indented: Bool = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(session.terminalInfo) · \(session.projectName)")
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(viewModel.formatElapsedTime(session.createdAt))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isHovered {
                Button(action: { viewModel.showSession(session) }) {
                    Image(systemName: "arrow.right.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, indented ? 28 : 12)  // Extra indent for grouped sessions
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.1) : Color.clear)
        .onHover { isHovered = $0 }
        .onTapGesture {
            viewModel.showSession(session)
        }
        .contextMenu {
            Menu("Move to Group") {
                // Option to remove from group (ungrouped)
                Button {
                    viewModel.moveSession(session, toGroup: nil)
                } label: {
                    HStack {
                        if session.groupId == nil {
                            Image(systemName: "checkmark")
                        }
                        Text("None")
                    }
                }

                Divider()

                // List all available groups
                ForEach(viewModel.sortedGroups, id: \.id) { group in
                    Button {
                        viewModel.moveSession(session, toGroup: group.id)
                    } label: {
                        HStack {
                            if session.groupId == group.id {
                                Image(systemName: "checkmark")
                            }
                            Circle()
                                .fill(Color(hex: group.colorHex) ?? .gray)
                                .frame(width: 8, height: 8)
                            Text(group.name)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Drop Delegates

struct GroupDropDelegate: DropDelegate {
    let group: SessionGroup
    let viewModel: SessionsViewModel
    @Binding var draggingGroup: SessionGroup?
    @Binding var draggingSession: ClaudeSession?
    @Binding var isTargeted: Bool

    func performDrop(info: DropInfo) -> Bool {
        // Handle session drop (move to this group)
        if let session = draggingSession {
            viewModel.moveSession(session, toGroup: group.id)
            draggingSession = nil
            isTargeted = false
            return true
        }
        draggingGroup = nil
        isTargeted = false
        return false
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        // Handle group reordering
        guard let dragging = draggingGroup, dragging.id != group.id else { return }
        viewModel.reorderGroup(dragging, before: group)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func validateDrop(info: DropInfo) -> Bool {
        return draggingGroup != nil || draggingSession != nil
    }
}

struct UngroupedDropDelegate: DropDelegate {
    let viewModel: SessionsViewModel
    @Binding var draggingSession: ClaudeSession?

    func performDrop(info: DropInfo) -> Bool {
        if let session = draggingSession {
            viewModel.moveSession(session, toGroup: nil)
            draggingSession = nil
            return true
        }
        return false
    }

    func validateDrop(info: DropInfo) -> Bool {
        return draggingSession != nil
    }
}

// MARK: - ViewModel

class SessionsViewModel: ObservableObject {
    @Published var sessions: [ClaudeSession] = []
    @Published var groups: [SessionGroup] = []

    private let sessionManager = SessionManager.shared
    weak var appDelegate: AppDelegate?

    init() {
        refresh()
        sessionManager.onSessionsChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
    }

    func refresh() {
        sessions = sessionManager.sessions
        groups = sessionManager.groups
    }

    var runningSessions: [ClaudeSession] {
        sessions.filter { $0.status == .running }
    }

    var sortedGroups: [SessionGroup] {
        groups.sorted { $0.order < $1.order }
    }

    var ungroupedSessions: [ClaudeSession] {
        runningSessions
            .filter { $0.groupId == nil }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var hasGroupedSessions: Bool {
        runningSessions.contains { $0.groupId != nil }
    }

    func sessions(for group: SessionGroup) -> [ClaudeSession] {
        runningSessions
            .filter { $0.groupId == group.id }
            .sorted { $0.createdAt > $1.createdAt }
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

    func showSession(_ session: ClaudeSession) {
        sessionManager.navigateToSession(id: session.id)
        appDelegate?.closePopover()
    }

    func moveSession(_ session: ClaudeSession, toGroup groupId: String?) {
        sessionManager.setSessionGroup(sessionId: session.id, groupId: groupId)
    }

    func reorderGroup(_ dragging: SessionGroup, before target: SessionGroup) {
        let sorted = sortedGroups
        guard let fromIndex = sorted.firstIndex(where: { $0.id == dragging.id }),
              let toIndex = sorted.firstIndex(where: { $0.id == target.id }),
              fromIndex != toIndex else { return }

        // Update orders
        var newOrder = sorted
        newOrder.remove(at: fromIndex)
        newOrder.insert(dragging, at: toIndex)

        for (index, group) in newOrder.enumerated() {
            sessionManager.updateGroup(id: group.id, order: index)
        }
    }

    func openSettings() {
        appDelegate?.openSettingsWindow()
    }
}

// MARK: - Settings View

struct SettingsView: View {
    let sessionManager: SessionManager
    @State private var notificationEnabled: Bool
    @State private var soundEnabled: Bool
    @State private var voiceEnabled: Bool
    @State private var reminderEnabled: Bool
    @State private var reminderInterval: Int
    @State private var reminderCount: Int
    @State private var groups: [SessionGroup]
    @State private var showingAddGroup = false
    @State private var newGroupName = ""
    @State private var newGroupColor = "#FFB3BA"

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        _notificationEnabled = State(initialValue: sessionManager.notificationEnabled)
        _soundEnabled = State(initialValue: sessionManager.soundEnabled)
        _voiceEnabled = State(initialValue: sessionManager.voiceEnabled)
        _reminderEnabled = State(initialValue: sessionManager.reminderEnabled)
        _reminderInterval = State(initialValue: sessionManager.reminderInterval)
        _reminderCount = State(initialValue: sessionManager.reminderCount)
        _groups = State(initialValue: sessionManager.groups)
    }

    var body: some View {
        Form {
            Section("Alerts") {
                Toggle("Notification", isOn: $notificationEnabled)
                    .onChange(of: notificationEnabled) { new in
                        sessionManager.notificationEnabled = new
                    }
                Toggle("Sound", isOn: $soundEnabled)
                    .onChange(of: soundEnabled) { new in
                        sessionManager.soundEnabled = new
                    }
                Toggle("Voice", isOn: $voiceEnabled)
                    .onChange(of: voiceEnabled) { new in
                        sessionManager.voiceEnabled = new
                    }
            }

            Section("Reminders") {
                Toggle("Enabled", isOn: $reminderEnabled)
                    .onChange(of: reminderEnabled) { new in
                        sessionManager.reminderEnabled = new
                    }

                Picker("Interval", selection: $reminderInterval) {
                    Text("30 sec").tag(30)
                    Text("1 min").tag(60)
                    Text("2 min").tag(120)
                    Text("5 min").tag(300)
                }
                .onChange(of: reminderInterval) { new in
                    sessionManager.reminderInterval = new
                }

                Picker("Count", selection: $reminderCount) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                    Text("5").tag(5)
                    Text("∞ Infinite").tag(0)
                }
                .onChange(of: reminderCount) { new in
                    sessionManager.reminderCount = new
                }
            }

            Section("Groups") {
                ForEach(groups.sorted { $0.order < $1.order }, id: \.id) { group in
                    HStack {
                        Circle()
                            .fill(Color(hex: group.colorHex) ?? .gray)
                            .frame(width: 12, height: 12)
                        Text(group.name)
                        Spacer()
                        Button(action: { deleteGroup(group) }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button("Add Group...") {
                    showingAddGroup = true
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingAddGroup) {
            VStack(spacing: 16) {
                Text("New Group")
                    .font(.headline)

                TextField("Name", text: $newGroupName)
                    .textFieldStyle(.roundedBorder)

                Picker("Color", selection: $newGroupColor) {
                    ForEach(SessionGroup.availableColors, id: \.hex) { color in
                        HStack {
                            Circle()
                                .fill(Color(hex: color.hex) ?? .gray)
                                .frame(width: 12, height: 12)
                            Text(color.name)
                        }
                        .tag(color.hex)
                    }
                }

                HStack {
                    Button("Cancel") {
                        showingAddGroup = false
                        newGroupName = ""
                    }
                    Spacer()
                    Button("Create") {
                        if !newGroupName.isEmpty {
                            _ = sessionManager.createGroup(name: newGroupName, colorHex: newGroupColor)
                            groups = sessionManager.groups
                            newGroupName = ""
                            showingAddGroup = false
                        }
                    }
                    .disabled(newGroupName.isEmpty)
                }
            }
            .padding()
            .frame(width: 300)
        }
    }

    func deleteGroup(_ group: SessionGroup) {
        sessionManager.deleteGroup(id: group.id)
        groups = sessionManager.groups
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var sessionManager: SessionManager!
    var popover: NSPopover!
    var viewModel: SessionsViewModel!
    var settingsWindow: NSWindow?
    var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set notification delegate FIRST
        UNUserNotificationCenter.current().delegate = self

        // Initialize session manager
        sessionManager = SessionManager.shared

        // Setup view model
        viewModel = SessionsViewModel()
        viewModel.appDelegate = self

        // Setup popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: SessionsPopoverView(viewModel: viewModel))

        // Setup menu bar
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
            NSLog("Notification action for session: \(sessionId), action: \(response.actionIdentifier)")

            // Handle click, Show action, or dismiss - all acknowledge the session
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier ||
               response.actionIdentifier == SessionManager.showActionId {
                // User clicked or tapped Show - navigate to session
                sessionManager.navigateToSession(id: sessionId)
                sessionManager.acknowledgeSession(id: sessionId)
            } else if response.actionIdentifier == UNNotificationDismissActionIdentifier {
                // User dismissed the notification - just acknowledge (cancel reminders)
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
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Update icon based on running sessions
        updateIconBadge()

        // Listen for session changes
        sessionManager.onSessionsChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.updateIconBadge()
                self?.viewModel.refresh()
            }
        }
    }

    @objc func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        if let button = statusItem.button {
            viewModel.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Close popover when clicking outside
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.closePopover()
            }
        }
    }

    func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func openSettingsWindow() {
        closePopover()

        if settingsWindow == nil {
            let settingsView = SettingsView(sessionManager: sessionManager)
            let hostingController = NSHostingController(rootView: settingsView)
            settingsWindow = NSWindow(contentViewController: hostingController)
            settingsWindow?.title = "Beacon Settings"
            settingsWindow?.styleMask = [.titled, .closable, .resizable]
            settingsWindow?.setContentSize(NSSize(width: 400, height: 500))
            settingsWindow?.center()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateIconBadge() {
        let runningCount = sessionManager.sessions.filter { $0.status == .running }.count

        if let button = statusItem.button {
            if runningCount > 0 {
                button.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "Beacon - \(runningCount) running")
            } else {
                button.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Beacon")
            }
            button.image?.isTemplate = true
        }
    }

    // MARK: - Actions

    @objc func refresh() {
        sessionManager.triggerScan()
        viewModel.refresh()
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
