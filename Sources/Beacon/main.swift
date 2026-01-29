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

                        // Ungrouped sessions (always show when there are groups for drop target)
                        if !viewModel.ungroupedSessions.isEmpty || !viewModel.sortedGroups.isEmpty {
                            UngroupedSectionView(
                                sessions: viewModel.ungroupedSessions,
                                viewModel: viewModel,
                                draggingSession: $draggingSession
                            )
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
    @State private var isHovered = false
    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var showColorPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header - always visible for drag targets
            HStack(spacing: 6) {
                // Expand/collapse chevron
                Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 12)

                Circle()
                    .fill(Color(hex: group.colorHex) ?? .gray)
                    .frame(width: 10, height: 10)
                    .onTapGesture {
                        showColorPicker = true
                    }
                    .popover(isPresented: $showColorPicker) {
                        ColorPickerPopover(
                            selectedColor: group.colorHex,
                            onSelectColor: { colorHex in
                                viewModel.setGroupColor(groupId: group.id, colorHex: colorHex)
                                showColorPicker = false
                            }
                        )
                    }

                if isEditingName {
                    TextField("Group name", text: $editedName, onCommit: {
                        if !editedName.isEmpty {
                            viewModel.renameGroup(groupId: group.id, name: editedName)
                        }
                        isEditingName = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: 150)
                    .onExitCommand {
                        isEditingName = false
                    }
                } else {
                    Text(group.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .onTapGesture(count: 2) {
                            editedName = group.name
                            isEditingName = true
                        }
                }

                Spacer()
                if sessions.isEmpty && !isHovered && !isEditingName {
                    Text("Drop here")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.6))
                }
                if isHovered && !isEditingName {
                    Menu {
                        GroupSettingsMenu(group: group, viewModel: viewModel)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 20)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isTargeted ? Color.accentColor.opacity(0.2) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture {
                if !isEditingName {
                    viewModel.toggleGroupExpanded(groupId: group.id)
                }
            }
            .onHover { isHovered = $0 }

            // Sessions (indented as children) - only show when expanded
            if group.isExpanded {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    SessionRowView(session: session, viewModel: viewModel, indented: true)
                        .onDrag {
                            draggingSession = session
                            return NSItemProvider(object: session.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: SessionReorderDropDelegate(
                            targetSession: session,
                            targetIndex: index,
                            allSessions: sessions,
                            group: group,
                            viewModel: viewModel,
                            draggingSession: $draggingSession
                        ))
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

struct ColorPickerPopover: View {
    let selectedColor: String
    let onSelectColor: (String) -> Void
    @State private var customHex = ""
    @State private var showCustomInput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Color")
                .font(.headline)

            // Preset colors grid
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 5), spacing: 8) {
                ForEach(SessionGroup.availableColors, id: \.hex) { color in
                    Circle()
                        .fill(Color(hex: color.hex) ?? .gray)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.primary, lineWidth: selectedColor == color.hex ? 2 : 0)
                        )
                        .onTapGesture {
                            onSelectColor(color.hex)
                        }
                }
            }

            Divider()

            // Custom color input
            HStack {
                TextField("Custom HEX", text: $customHex)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)

                if let color = Color(hex: customHex.hasPrefix("#") ? customHex : "#\(customHex)") {
                    Circle()
                        .fill(color)
                        .frame(width: 20, height: 20)

                    Button("Apply") {
                        let hex = customHex.hasPrefix("#") ? customHex : "#\(customHex)"
                        onSelectColor(hex)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding()
        .frame(width: 220)
    }
}

struct GroupSettingsMenu: View {
    let group: SessionGroup
    @ObservedObject var viewModel: SessionsViewModel

    var body: some View {
        // Alert overrides
        Menu("Alerts") {
            Toggle("Notification", isOn: Binding(
                get: { group.notificationOverride ?? true },
                set: { viewModel.setGroupOverride(groupId: group.id, notification: $0) }
            ))
            Toggle("Sound", isOn: Binding(
                get: { group.soundOverride ?? true },
                set: { viewModel.setGroupOverride(groupId: group.id, sound: $0) }
            ))
            Toggle("Voice", isOn: Binding(
                get: { group.voiceOverride ?? true },
                set: { viewModel.setGroupOverride(groupId: group.id, voice: $0) }
            ))
            Toggle("Reminder", isOn: Binding(
                get: { group.reminderOverride ?? true },
                set: { viewModel.setGroupOverride(groupId: group.id, reminder: $0) }
            ))

            Divider()

            Button("Use Global Settings") {
                viewModel.clearGroupOverrides(groupId: group.id)
            }
        }

        // Color picker
        Menu("Color") {
            ForEach(SessionGroup.availableColors, id: \.hex) { color in
                Button {
                    viewModel.setGroupColor(groupId: group.id, colorHex: color.hex)
                } label: {
                    HStack {
                        if group.colorHex == color.hex {
                            Image(systemName: "checkmark")
                        }
                        Circle()
                            .fill(Color(hex: color.hex) ?? .gray)
                            .frame(width: 10, height: 10)
                        Text(color.name)
                    }
                }
            }
        }

        Divider()

        Button("Delete Group", role: .destructive) {
            viewModel.deleteGroup(groupId: group.id)
        }
    }
}

struct UngroupedSectionView: View {
    let sessions: [ClaudeSession]
    @ObservedObject var viewModel: SessionsViewModel
    @Binding var draggingSession: ClaudeSession?
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (show when there are groups)
            if !viewModel.sortedGroups.isEmpty {
                HStack(spacing: 4) {
                    Circle()
                        .strokeBorder(Color.secondary, lineWidth: 1)
                        .frame(width: 8, height: 8)
                    Text("Ungrouped")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    if sessions.isEmpty {
                        Text("Drop to ungroup")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isTargeted ? Color.accentColor.opacity(0.2) : Color.clear)
            }

            ForEach(sessions, id: \.id) { session in
                SessionRowView(session: session, viewModel: viewModel)
                    .onDrag {
                        draggingSession = session
                        return NSItemProvider(object: session.id as NSString)
                    }
            }

            // Spacer area to make drop target larger when empty
            if sessions.isEmpty && !viewModel.sortedGroups.isEmpty {
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 30)
            }
        }
        .background(isTargeted ? Color.accentColor.opacity(0.05) : Color.clear)
        .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
            if let session = draggingSession, session.groupId != nil {
                viewModel.moveSession(session, toGroup: nil)
                draggingSession = nil
                return true
            }
            return false
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
                Text(viewModel.formatLastAlert(session, tick: viewModel.tick))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isHovered {
                Menu {
                    SessionSettingsMenu(session: session, viewModel: viewModel)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)

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
        .contentShape(Rectangle())  // Make entire row tappable
        .onHover { isHovered = $0 }
        .onTapGesture {
            viewModel.showSession(session)
        }
    }
}

struct SessionSettingsMenu: View {
    let session: ClaudeSession
    @ObservedObject var viewModel: SessionsViewModel

    var body: some View {
        // Move to group
        Menu("Move to Group") {
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

        // Alert overrides
        Menu("Alerts") {
            Toggle("Notification", isOn: Binding(
                get: { session.notificationOverride ?? true },
                set: { viewModel.setSessionOverride(sessionId: session.id, notification: $0) }
            ))
            Toggle("Sound", isOn: Binding(
                get: { session.soundOverride ?? true },
                set: { viewModel.setSessionOverride(sessionId: session.id, sound: $0) }
            ))
            Toggle("Voice", isOn: Binding(
                get: { session.voiceOverride ?? true },
                set: { viewModel.setSessionOverride(sessionId: session.id, voice: $0) }
            ))
            Toggle("Reminder", isOn: Binding(
                get: { session.reminderOverride ?? true },
                set: { viewModel.setSessionOverride(sessionId: session.id, reminder: $0) }
            ))

            Divider()

            Button("Use Global Settings") {
                viewModel.clearSessionOverrides(sessionId: session.id)
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

struct SessionReorderDropDelegate: DropDelegate {
    let targetSession: ClaudeSession
    let targetIndex: Int
    let allSessions: [ClaudeSession]
    let group: SessionGroup
    let viewModel: SessionsViewModel
    @Binding var draggingSession: ClaudeSession?

    private func reorderBasedOnLocation(_ info: DropInfo, dragging: ClaudeSession) {
        // Determine if dropping in top or bottom half based on drop location
        // Row height is approximately 36 points (padding + content)
        let rowHeight: CGFloat = 36
        let dropY = info.location.y
        let isBottomHalf = dropY > rowHeight / 2

        if isBottomHalf {
            // Insert after target - find the next session
            let nextIndex = targetIndex + 1
            if nextIndex < allSessions.count {
                viewModel.reorderSession(dragging, before: allSessions[nextIndex])
            } else {
                // Insert at end (before nil)
                viewModel.reorderSession(dragging, before: nil)
            }
        } else {
            // Insert before target
            viewModel.reorderSession(dragging, before: targetSession)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragging = draggingSession else { return false }

        // If dragging session is from a different group, move it to this group first
        if dragging.groupId != group.id {
            viewModel.moveSession(dragging, toGroup: group.id)
            // After moving to group, reorder within it
            reorderBasedOnLocation(info, dragging: dragging)
        }

        draggingSession = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingSession,
              dragging.id != targetSession.id,
              dragging.groupId == group.id else { return }

        // Live reordering preview with midpoint detection
        reorderBasedOnLocation(info, dragging: dragging)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Continue updating position as drag moves
        if let dragging = draggingSession,
           dragging.id != targetSession.id,
           dragging.groupId == group.id {
            reorderBasedOnLocation(info, dragging: dragging)
        }
        return DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        return draggingSession != nil && draggingSession?.id != targetSession.id
    }
}


// MARK: - ViewModel

class SessionsViewModel: ObservableObject {
    @Published var sessions: [ClaudeSession] = []
    @Published var groups: [SessionGroup] = []
    @Published var tick: Int = 0

    private let sessionManager = SessionManager.shared
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    weak var appDelegate: AppDelegate?

    init() {
        refresh()
        sessionManager.onSessionsChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
        // Fast timer (1s) for recent alerts
        fastTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Only tick if there's a recent alert (within 1 min)
            let hasRecentAlert = self.sessions.contains { session in
                if let alertTime = session.alertTriggeredAt {
                    return Date().timeIntervalSince(alertTime) < 60
                }
                return false
            }
            if hasRecentAlert {
                self.tick += 1
            }
        }
        // Slow timer (10s) for older alerts
        slowTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.tick += 1
        }
    }

    deinit {
        fastTimer?.invalidate()
        slowTimer?.invalidate()
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
            .sorted { $0.orderInGroup < $1.orderInGroup }
    }

    func formatLastAlert(_ session: ClaudeSession, tick: Int = 0) -> String {
        _ = tick  // Force refresh
        if let alertTime = session.alertTriggeredAt {
            let elapsed = Int(Date().timeIntervalSince(alertTime))
            return "Last task: \(formatElapsed(elapsed, recent: elapsed < 60))"
        } else if session.detectedMidRun {
            // Session was already running when Beacon started, unknown start time
            return "Last task: unknown"
        } else {
            let elapsed = Int(Date().timeIntervalSince(session.createdAt))
            return "Last task: \(formatElapsed(elapsed, recent: false))"
        }
    }

    func formatElapsed(_ seconds: Int, recent: Bool) -> String {
        if recent {
            // Show exact seconds for recent alerts
            return "\(seconds)s"
        } else if seconds < 10 {
            return "<10s"
        } else if seconds < 30 {
            return "<30s"
        } else if seconds < 60 {
            return "<1m"
        } else if seconds < 3600 {
            return "\(seconds / 60)m"
        } else {
            return "\(seconds / 3600)h"
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

    // MARK: - Group Settings

    func setGroupOverride(groupId: String, notification: Bool? = nil, sound: Bool? = nil, voice: Bool? = nil, reminder: Bool? = nil) {
        if let notification = notification {
            sessionManager.setGroupNotificationOverride(id: groupId, enabled: notification)
        }
        if let sound = sound {
            sessionManager.setGroupSoundOverride(id: groupId, enabled: sound)
        }
        if let voice = voice {
            sessionManager.setGroupVoiceOverride(id: groupId, enabled: voice)
        }
        if let reminder = reminder {
            sessionManager.setGroupReminderOverride(id: groupId, enabled: reminder)
        }
    }

    func clearGroupOverrides(groupId: String) {
        sessionManager.setGroupNotificationOverride(id: groupId, enabled: nil)
        sessionManager.setGroupSoundOverride(id: groupId, enabled: nil)
        sessionManager.setGroupVoiceOverride(id: groupId, enabled: nil)
        sessionManager.setGroupReminderOverride(id: groupId, enabled: nil)
    }

    func setGroupColor(groupId: String, colorHex: String) {
        sessionManager.updateGroup(id: groupId, colorHex: colorHex)
    }

    func renameGroup(groupId: String, name: String) {
        sessionManager.updateGroup(id: groupId, name: name)
    }

    func deleteGroup(groupId: String) {
        sessionManager.deleteGroup(id: groupId)
    }

    func toggleGroupExpanded(groupId: String) {
        sessionManager.toggleGroupExpanded(id: groupId)
    }

    // MARK: - Session Settings

    func setSessionOverride(sessionId: String, notification: Bool? = nil, sound: Bool? = nil, voice: Bool? = nil, reminder: Bool? = nil) {
        if let notification = notification {
            sessionManager.setSessionNotificationOverride(id: sessionId, enabled: notification)
        }
        if let sound = sound {
            sessionManager.setSessionSoundOverride(id: sessionId, enabled: sound)
        }
        if let voice = voice {
            sessionManager.setSessionVoiceOverride(id: sessionId, enabled: voice)
        }
        if let reminder = reminder {
            sessionManager.setSessionReminderOverride(id: sessionId, enabled: reminder)
        }
    }

    func clearSessionOverrides(sessionId: String) {
        sessionManager.setSessionNotificationOverride(id: sessionId, enabled: nil)
        sessionManager.setSessionSoundOverride(id: sessionId, enabled: nil)
        sessionManager.setSessionVoiceOverride(id: sessionId, enabled: nil)
        sessionManager.setSessionReminderOverride(id: sessionId, enabled: nil)
    }

    func reorderSession(_ session: ClaudeSession, before targetSession: ClaudeSession?) {
        sessionManager.reorderSessionInGroup(sessionId: session.id, beforeSessionId: targetSession?.id)
    }

    func reorderSessionToEnd(_ session: ClaudeSession) {
        sessionManager.reorderSessionInGroup(sessionId: session.id, beforeSessionId: nil)
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
    @State private var pronunciationRules: [String: String]
    @State private var showingAddRule = false
    @State private var newRulePattern = ""
    @State private var newRulePronunciation = ""
    @State private var selectedEnglishVoice: String
    @State private var selectedKoreanVoice: String

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        _notificationEnabled = State(initialValue: sessionManager.notificationEnabled)
        _soundEnabled = State(initialValue: sessionManager.soundEnabled)
        _voiceEnabled = State(initialValue: sessionManager.voiceEnabled)
        _reminderEnabled = State(initialValue: sessionManager.reminderEnabled)
        _reminderInterval = State(initialValue: sessionManager.reminderInterval)
        _reminderCount = State(initialValue: sessionManager.reminderCount)
        _groups = State(initialValue: sessionManager.groups)
        _pronunciationRules = State(initialValue: sessionManager.pronunciationRules)
        _selectedEnglishVoice = State(initialValue: sessionManager.selectedEnglishVoice)
        _selectedKoreanVoice = State(initialValue: sessionManager.selectedKoreanVoice)
    }

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // General Tab - Alerts, Reminders, About
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(0)

            // Groups Tab
            groupsTab
                .tabItem {
                    Label("Groups", systemImage: "folder")
                }
                .tag(1)

            // Pronunciation Tab
            pronunciationTab
                .tabItem {
                    Label("Voice", systemImage: "waveform")
                }
                .tag(2)
        }
        .frame(minWidth: 400, minHeight: 350)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
        )
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
        .sheet(isPresented: $showingAddRule) {
            AddRuleSheet(
                sessionManager: sessionManager,
                isPresented: $showingAddRule,
                pronunciationRules: $pronunciationRules
            )
        }
        .onDisappear {
            // Resign first responder when settings view closes to save any pending edits
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
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

                Button("Test Alerts") {
                    sessionManager.testAlerts()
                }
            }

            Section("Reminders") {
                Toggle("Enabled", isOn: $reminderEnabled)
                    .onChange(of: reminderEnabled) { new in
                        sessionManager.reminderEnabled = new
                    }

                Picker("Interval", selection: $reminderInterval) {
                    Text("1 min").tag(60)
                    Text("2 min").tag(120)
                    Text("5 min").tag(300)
                    Text("10 min").tag(600)
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

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(SessionManager.appVersion)
                        .foregroundColor(.secondary)
                }

                if sessionManager.updateAvailable {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Version \(sessionManager.latestVersion) available")
                                .font(.headline)
                            if !sessionManager.releaseNotes.isEmpty {
                                Text(sessionManager.releaseNotes.prefix(100) + (sessionManager.releaseNotes.count > 100 ? "..." : ""))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Button("View Release") {
                            sessionManager.openReleasePage()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    // MARK: - Groups Tab

    private var groupsTab: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(groups.sorted { $0.order < $1.order }, id: \.id) { group in
                        GroupSettingsRow(
                            group: group,
                            onUpdateName: { newName in
                                sessionManager.updateGroup(id: group.id, name: newName)
                                groups = sessionManager.groups
                            },
                            onUpdateColor: { newColor in
                                sessionManager.updateGroup(id: group.id, colorHex: newColor)
                                groups = sessionManager.groups
                            },
                            onDelete: {
                                deleteGroup(group)
                            }
                        )
                        .padding(.horizontal)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 8)
            }

            Divider()

            HStack {
                Spacer()
                Button("Add Group...") {
                    showingAddGroup = true
                }
                .padding()
            }
        }
    }

    // MARK: - Pronunciation Tab

    private var pronunciationTab: some View {
        VStack(spacing: 0) {
            // Pronunciation Rules Section (top, scrollable)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pronunciation Rules")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top, 16)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(pronunciationRules.keys.sorted()), id: \.self) { pattern in
                            PronunciationRuleRow(
                                pattern: pattern,
                                pronunciation: pronunciationRules[pattern] ?? "",
                                onUpdatePattern: { newPattern in
                                    let oldPronunciation = pronunciationRules[pattern] ?? ""
                                    sessionManager.removePronunciationRule(pattern: pattern)
                                    sessionManager.addPronunciationRule(pattern: newPattern, pronunciation: oldPronunciation)
                                    pronunciationRules = sessionManager.pronunciationRules
                                },
                                onUpdatePronunciation: { newPronunciation in
                                    sessionManager.addPronunciationRule(pattern: pattern, pronunciation: newPronunciation)
                                    pronunciationRules = sessionManager.pronunciationRules
                                },
                                onDelete: {
                                    deleteRule(pattern)
                                }
                            )
                            .padding(.horizontal)
                        }

                        if pronunciationRules.isEmpty {
                            Text("No pronunciation rules")
                                .foregroundColor(.secondary)
                                .padding()
                        }
                    }
                    .padding(.vertical, 4)
                }

                HStack {
                    Spacer()
                    Button("Add Rule...") {
                        showingAddRule = true
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }

            Divider()

            // Voice Selection Section (bottom)
            Form {
                Section("Voice Selection") {
                    Picker("English Voice", selection: $selectedEnglishVoice) {
                        ForEach(sessionManager.getEnglishVoices(), id: \.id) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    }
                    .onChange(of: selectedEnglishVoice) { newValue in
                        sessionManager.selectedEnglishVoice = newValue
                    }

                    Picker("Korean Voice", selection: $selectedKoreanVoice) {
                        ForEach(sessionManager.getKoreanVoices(), id: \.id) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    }
                    .onChange(of: selectedKoreanVoice) { newValue in
                        sessionManager.selectedKoreanVoice = newValue
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 130)
        }
    }

    func deleteGroup(_ group: SessionGroup) {
        sessionManager.deleteGroup(id: group.id)
        groups = sessionManager.groups
    }

    func deleteRule(_ pattern: String) {
        sessionManager.removePronunciationRule(pattern: pattern)
        pronunciationRules = sessionManager.pronunciationRules
    }
}

struct GroupSettingsRow: View {
    let group: SessionGroup
    let onUpdateName: (String) -> Void
    let onUpdateColor: (String) -> Void
    let onDelete: () -> Void

    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var showColorPicker = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack {
            Circle()
                .fill(Color(hex: group.colorHex) ?? .gray)
                .frame(width: 12, height: 12)
                .onTapGesture {
                    showColorPicker = true
                }
                .popover(isPresented: $showColorPicker) {
                    ColorPickerPopover(
                        selectedColor: group.colorHex,
                        onSelectColor: { colorHex in
                            onUpdateColor(colorHex)
                            showColorPicker = false
                        }
                    )
                }

            if isEditingName {
                TextField("Group name", text: $editedName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 150)
                    .focused($nameFocused)
                    .onSubmit {
                        saveName()
                    }
                    .onChange(of: nameFocused) { focused in
                        if !focused {
                            saveName()
                        }
                    }
            } else {
                Text(group.name)
                    .onTapGesture {
                        editedName = group.name
                        isEditingName = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            nameFocused = true
                        }
                    }
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
    }

    private func saveName() {
        if !editedName.isEmpty && editedName != group.name {
            onUpdateName(editedName)
        }
        isEditingName = false
    }
}

struct PronunciationRuleRow: View {
    let pattern: String
    let pronunciation: String
    let onUpdatePattern: (String) -> Void
    let onUpdatePronunciation: (String) -> Void
    let onDelete: () -> Void

    @State private var isEditingPattern = false
    @State private var isEditingPronunciation = false
    @State private var editedPattern = ""
    @State private var editedPronunciation = ""
    @FocusState private var patternFocused: Bool
    @FocusState private var pronunciationFocused: Bool

    var body: some View {
        HStack {
            if isEditingPattern {
                TextField("Pattern", text: $editedPattern)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                    .focused($patternFocused)
                    .onSubmit {
                        savePattern()
                    }
                    .onChange(of: patternFocused) { focused in
                        if !focused {
                            savePattern()
                        }
                    }
            } else {
                Text(pattern)
                    .fontWeight(.medium)
                    .onTapGesture {
                        editedPattern = pattern
                        isEditingPattern = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            patternFocused = true
                        }
                    }
            }

            Image(systemName: "arrow.right")
                .foregroundColor(.secondary)

            if isEditingPronunciation {
                TextField("Pronunciation", text: $editedPronunciation)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                    .focused($pronunciationFocused)
                    .onSubmit {
                        savePronunciation()
                    }
                    .onChange(of: pronunciationFocused) { focused in
                        if !focused {
                            savePronunciation()
                        }
                    }
            } else {
                Text(pronunciation)
                    .foregroundColor(.secondary)
                    .onTapGesture {
                        editedPronunciation = pronunciation
                        isEditingPronunciation = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            pronunciationFocused = true
                        }
                    }
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
    }

    private func savePattern() {
        if !editedPattern.isEmpty && editedPattern != pattern {
            onUpdatePattern(editedPattern)
        }
        isEditingPattern = false
    }

    private func savePronunciation() {
        if !editedPronunciation.isEmpty && editedPronunciation != pronunciation {
            onUpdatePronunciation(editedPronunciation)
        }
        isEditingPronunciation = false
    }
}

struct AddRuleSheet: View {
    let sessionManager: SessionManager
    @Binding var isPresented: Bool
    @Binding var pronunciationRules: [String: String]
    @State private var pattern = ""
    @State private var pronunciation = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Pronunciation Rule")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("When voice says:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Pattern (e.g., Beacon)", text: $pattern)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Pronounce as:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Pronunciation (e.g., 비콘)", text: $pronunciation)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                    pattern = ""
                    pronunciation = ""
                }
                Spacer()
                Button("Test") {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    task.arguments = [pronunciation.isEmpty ? pattern : pronunciation]
                    try? task.run()
                }
                .disabled(pattern.isEmpty && pronunciation.isEmpty)
                Button("Add") {
                    if !pattern.isEmpty && !pronunciation.isEmpty {
                        sessionManager.addPronunciationRule(pattern: pattern, pronunciation: pronunciation)
                        pronunciationRules = sessionManager.pronunciationRules
                        pattern = ""
                        pronunciation = ""
                        isPresented = false
                    }
                }
                .disabled(pattern.isEmpty || pronunciation.isEmpty)
            }
        }
        .padding()
        .frame(width: 320)
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
        let userInfo = response.notification.request.content.userInfo
        let isReminder = userInfo["isReminder"] as? Bool ?? false

        // Debug: write to file to verify handler is called
        let logPath = NSHomeDirectory() + "/beacon_notification_debug.log"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "\(timestamp) - didReceive called, isReminder: \(isReminder), action: \(response.actionIdentifier)\n"
        if let data = logLine.data(using: .utf8) {
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

        NSLog("Notification response received - isReminder: \(isReminder), userInfo: \(userInfo)")

        if let sessionId = userInfo["sessionId"] as? String {
            NSLog("Notification action for session: \(sessionId), action: \(response.actionIdentifier)")

            // Handle click, Show action, or dismiss - all acknowledge the session
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier ||
               response.actionIdentifier == SessionManager.showActionId {
                // User clicked or tapped Show - navigate to session
                NSLog("Navigating to session: \(sessionId)")
                sessionManager.navigateToSession(id: sessionId)
                sessionManager.acknowledgeSession(id: sessionId)
            } else if response.actionIdentifier == UNNotificationDismissActionIdentifier {
                // User dismissed the notification - just acknowledge (cancel reminders)
                sessionManager.acknowledgeSession(id: sessionId)
            }
        } else {
            NSLog("No sessionId found in notification userInfo")
        }
        completionHandler()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Beacon")
            image?.isTemplate = true  // Use template mode for proper menu bar appearance (white on dark, black on light)
            button.image = image
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
            // Ensure the button has valid bounds (can be invalid right after app launch)
            guard button.bounds.width > 0 && button.bounds.height > 0 else {
                // Retry after a short delay if bounds not ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.showPopover()
                }
                return
            }

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
        // Show badge only for completed sessions that we actually alerted about
        // Exclude sessions detected mid-run that haven't had an alert triggered
        let unacknowledgedCount = sessionManager.sessions.filter {
            $0.status == .completed && $0.alertTriggeredAt != nil
        }.count

        if let button = statusItem.button {
            let image: NSImage?
            if unacknowledgedCount > 0 {
                image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "Beacon - \(unacknowledgedCount) alerts")
            } else {
                image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Beacon")
            }
            image?.isTemplate = true  // Use template mode for proper menu bar appearance (white on dark, black on light)
            button.image = image
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
