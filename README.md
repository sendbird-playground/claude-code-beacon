# Beacon

A macOS menu bar app for managing Claude Code sessions across multiple terminals.

**No hooks required** - Beacon automatically detects Claude Code processes and notifies you when tasks complete.

## Features

- **Auto-Detection**: Automatically finds running Claude Code sessions
- **Task Completion Alerts**: Get notified when Claude finishes a task
- **Re-Alarm System**: PagerDuty-style reminders every 60 seconds until acknowledged
- **Quick Navigation**: Click to jump directly to the terminal
- **Snooze**: Snooze notifications for 5 min, 15 min, or 1 hour
- **Multi-Terminal Support**: Works with WezTerm, iTerm2, Cursor, PyCharm, Terminal.app

## Installation

### Quick Install

```bash
cd ~/repo/Beacon
./install.sh
```

### Manual Build

```bash
swift build -c release
mkdir -p Beacon.app/Contents/MacOS
cp .build/release/Beacon Beacon.app/Contents/MacOS/
cp -r Beacon.app /Applications/
```

## Usage

1. Launch Beacon from Applications or Spotlight
2. Look for the bell icon in your menu bar
3. Beacon automatically monitors for Claude Code sessions
4. When a task completes, you'll receive a notification with options to:
   - **Go There** - Navigate to the terminal and acknowledge
   - **Acknowledge** - Mark as done
   - **Snooze** - Remind later

## Menu Bar Icon States

- 🔔 Bell - No pending tasks
- 🔔 Bell with badge - Tasks need attention

## How It Works

Beacon monitors your system for Claude Code processes every 5 seconds. When it detects a Claude process has ended (task completed), it:

1. Shows a macOS notification
2. Adds the session to the "Needs Attention" list
3. Re-alarms every 60 seconds until you acknowledge

No configuration or shell hooks needed!

## Start at Login

To have Beacon start automatically:
1. Open **System Settings**
2. Go to **General → Login Items**
3. Add **Beacon** to the list

## Requirements

- macOS 13.0 (Ventura) or later
- Swift 5.9+

## License

MIT
# claude-code-beacon
# claude-code-beacon
