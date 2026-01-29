# Beacon

![Version](https://img.shields.io/badge/version-1.0.0-blue)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![License](https://img.shields.io/badge/license-MIT-green)

A macOS menu bar app that monitors Claude Code sessions and notifies you when tasks complete.

## Features

### Core
- **Auto-Detection**: Automatically finds running Claude Code sessions across all terminals and IDEs
- **Task Completion Alerts**: Notification, sound, and voice alerts (individually toggleable)
- **Quick Navigation**: Click to jump directly to the terminal/IDE where the task completed
- **Multi-App Support**: Works with WezTerm, iTerm2, Terminal.app, VS Code, Cursor, PyCharm, and more

### Session Management
- **Session Groups**: Organize sessions into color-coded groups
- **Drag & Drop**: Reorder sessions within groups or move between groups
- **Per-Session Settings**: Override notification, sound, voice, and reminder settings per session
- **Per-Group Settings**: Set default overrides for all sessions in a group

### Reminders
- **Configurable Reminders**: Get reminded about unacknowledged tasks at 1, 2, 5, or 10 minute intervals
- **Reminder Count**: Set 1-5 reminders or infinite until acknowledged
- **Click to Dismiss**: Clicking a notification acknowledges the task and stops reminders

### Voice
- **Text-to-Speech**: Speaks the project name when a task completes
- **Language Detection**: Automatically uses Korean voice for Korean text, English for English
- **Pronunciation Rules**: Define custom pronunciations (e.g., "vitess" → "vitesse")

### Smart Features
- **DND Awareness**: Automatically suppresses sound and voice when Focus/Do Not Disturb is active
- **Auto-Update**: Checks for updates from git hourly, one-click update with automatic restart
- **Unknown Sessions**: Shows "Last task: unknown" for sessions detected mid-run (before Beacon started)
- **Backward Compatibility**: Safely preserves groups and settings across updates

## Installation

```bash
git clone git@github.com:sendbird-playground/claude-code-beacon.git
cd claude-code-beacon
./install.sh
```

## Usage

1. Launch Beacon from Applications
2. Bell icon appears in menu bar (badge shows unacknowledged alerts)
3. Click to see running sessions organized by groups
4. When a task completes, receive notification/sound/voice alert
5. Click notification or session to navigate and acknowledge

## Settings

Access via **⚙️** gear icon in the popover header:

### Alerts
- **Notification** - macOS notification banner
- **Sound** - Glass alert sound
- **Voice** - Speaks project name aloud
- **Test buttons** - Test sound and voice

### Reminders
- **Enabled** - Toggle reminder notifications
- **Interval** - 1, 2, 5, or 10 minutes between reminders
- **Count** - Number of reminders (1-5 or infinite)

### Groups
- Create groups with custom names and colors
- Double-click to edit group name inline
- Click color circle to change group color
- Drag sessions between groups

### Pronunciation Rules
- Add rules to customize how project names are spoken
- Click to edit pattern or pronunciation inline
- Useful for technical terms or non-English words

### Auto-Update
- Automatically checks GitHub releases hourly for updates
- Shows notification when new version is available
- One-click to view release page and download

## Start at Login

System Settings → General → Login Items → Add Beacon

## Requirements

- macOS 13.0+
- Swift 5.9+

## License

MIT
