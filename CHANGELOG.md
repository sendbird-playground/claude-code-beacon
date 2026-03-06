# Changelog

## [1.3.0] - 2026-03-05

### Added
- iTerm2 tab navigation support for session redirection
- Supported terminals & IDEs section in README

### Changed
- Zoom mic detection switched to in-process NSAppleScript for reliability
- Test alerts now respect DND and Zoom mic suppression

### Fixed
- Accessibility permission now properly prompted when enabling Zoom mute detection

## [1.2.0] - 2026-03-04

### Added
- Experimental Zoom meeting auto-mute for Beacon alerts
- Zoom mic detection via menu bar inspection with Korean locale support
- Cursor IDE window detection and plugin integration
- VS Code / Cursor plugin detection and installation in Settings
- About tab with feedback link in Settings

### Fixed
- Cursor window detection: use osascript instead of broken AX API
- Zoom mic detection substring match order for English locale

## [1.1.0] - 2026-02-13

### Added
- JetBrains plugin for reliable PyCharm terminal tab navigation
- Alert sound volume control (independent of system volume)
- Volume control applied to voice synthesis
- Voice selection for English and Korean in Settings
- Quality indicators for voice variants (Premium/Enhanced/Compact)
- Collapsible groups with persistent expand/collapse state
- Slack-style relative time in notifications
- Completion time in task notifications
- 5-minute snooze after clicking notification
- Auto-restart via LaunchAgent
- Test alerts button in Settings
- Tabbed Settings interface

### Fixed
- JSON parse error from newline in siblingCount breaking all alarms
- Alarm not firing: use /usr/bin/curl with 127.0.0.1, run hook synchronously
- PyCharm window raise using osascript subprocess
- Notification spam from sub-agents
- Double alerts by removing SubagentStop hook
- Orphaned reminder notifications on startup
- Running sessions not detected after acknowledgment
- Duplicate notifications for acknowledged sessions
- Voice selection showing currently selected voice
- Pronunciation rules not applied to voice output
- Notification icon display via time trigger and categoryIdentifier
- App bundle signing with correct bundle identifier

### Changed
- Don't send alerts when Claude is manually terminated (Ctrl+C)
- Skip notifications for stale sessions on app startup
- Removed reminder notification functionality (replaced by snooze)
- Removed redundant Show button and Quit button from menu

## [1.0.0] - 2026-01-29

### Added
- Initial release
- Auto-detection of Claude Code sessions across all terminals and IDEs
- Task completion alerts with notification, sound, and voice
- Quick navigation to terminal/IDE when clicking notification
- Multi-app support: WezTerm, iTerm2, Terminal.app, VS Code, Cursor, PyCharm
- Session groups with customizable colors
- Drag & drop to reorder sessions or move between groups
- Per-session and per-group settings overrides
- Configurable reminders (1, 2, 5, or 10 minute intervals)
- Reminder count options (1-5 or infinite)
- Language-aware voice (auto-detects English/Korean)
- Custom pronunciation rules for voice
- DND/Focus mode awareness (suppresses sound and voice)
- Auto-update checking via GitHub releases
- Backward compatible data storage
