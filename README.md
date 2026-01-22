# Beacon

A macOS menu bar app that monitors Claude Code sessions and notifies you when tasks complete.

## Features

- **Auto-Detection**: Automatically finds running Claude Code sessions
- **Task Completion Alerts**: Notification, sound, and voice alerts (individually toggleable)
- **Quick Navigation**: Click "Go There" to jump to the terminal/IDE
- **Multi-App Support**: Works with any terminal or IDE (WezTerm, iTerm2, VS Code, Cursor, PyCharm, etc.)
- **Background Process Detection**: Identifies orphaned Claude processes

## Installation

```bash
git clone git@github.com:sendbird-playground/claude-code-beacon.git
cd claude-code-beacon
./install.sh
```

## Usage

1. Launch Beacon from Applications
2. Bell icon appears in menu bar
3. Beacon automatically monitors for Claude Code sessions
4. When a task completes, you'll receive an alert

## Settings

Access via **⚙️ Settings** in the menu:

- **Notification** - macOS notification banner
- **Sound** - Alert sound
- **Voice** - Speaks project name
- **Max Recent Sessions** - 5, 10, 20, or 50

## Start at Login

System Settings → General → Login Items → Add Beacon

## Requirements

- macOS 13.0+
- Swift 5.9+

## License

MIT
