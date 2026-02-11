import Foundation

class HookManager {
    static let shared = HookManager()

    private let claudeDir: URL
    private let settingsFile: URL
    private let alertScriptFile: URL

    private init() {
        claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        settingsFile = claudeDir.appendingPathComponent("settings.json")
        alertScriptFile = claudeDir.appendingPathComponent("task-complete-alert.sh")
    }

    // MARK: - Check Hook Status

    var isHookInstalled: Bool {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else {
            return false
        }

        do {
            let data = try Data(contentsOf: settingsFile)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let hooks = json["hooks"] as? [String: Any],
               let stopHooks = hooks["Stop"] as? [[String: Any]] {
                // Check if our hook is present in Stop event
                return stopHooks.contains { entry in
                    if let innerHooks = entry["hooks"] as? [[String: Any]] {
                        return innerHooks.contains { hook in
                            if let command = hook["command"] as? String {
                                return command.contains("task-complete-alert.sh")
                            }
                            return false
                        }
                    }
                    return false
                }
            }
        } catch {
            print("Error reading settings: \(error)")
        }

        return false
    }

    var isAlertScriptInstalled: Bool {
        FileManager.default.fileExists(atPath: alertScriptFile.path)
    }

    // MARK: - Install Hooks

    func installHooks() -> (success: Bool, message: String) {
        // Create .claude directory if needed
        do {
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        } catch {
            return (false, "Failed to create .claude directory: \(error.localizedDescription)")
        }

        // Install the alert script
        let scriptResult = installAlertScript()
        if !scriptResult.success {
            return scriptResult
        }

        // Update settings.json with hook
        let hookResult = addHookToSettings()
        if !hookResult.success {
            return hookResult
        }

        return (true, "Hooks installed successfully! Restart Claude Code to activate.")
    }

    func uninstallHooks() -> (success: Bool, message: String) {
        // Remove hook from settings
        let result = removeHookFromSettings()
        return result
    }

    // MARK: - Alert Script

    private func installAlertScript() -> (success: Bool, message: String) {
        let script = generateAlertScript()

        do {
            try script.write(to: alertScriptFile, atomically: true, encoding: .utf8)

            // Make executable
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/chmod")
            task.arguments = ["+x", alertScriptFile.path]
            try task.run()
            task.waitUntilExit()

            return (true, "Alert script installed")
        } catch {
            return (false, "Failed to install alert script: \(error.localizedDescription)")
        }
    }

    private func generateAlertScript() -> String {
        return """
        #!/bin/bash

        #=============================================================================
        # Beacon Task Complete Alert Script
        # Automatically installed by Beacon - https://github.com/user/beacon
        #
        # ALERT STYLE CONFIGURATION (1-4):
        #   1 = {project}                           -> "vitess-ops"
        #   2 = {program}, {project}                -> "WezTerm, vitess-ops"
        #   3 = {program}, {project}, {summary}     -> "WezTerm, vitess-ops, fix"
        #   4 = Custom template (set BEACON_ALERT_TEMPLATE)
        #=============================================================================
        ALERT_STYLE="${BEACON_ALERT_STYLE:-3}"
        ALERT_TEMPLATE="${BEACON_ALERT_TEMPLATE:-Task {project} completed}"
        BEACON_PORT=19876

        # Get current working directory
        cwd="${PWD:-$(pwd)}"
        project_name=$(basename "$cwd")

        # Get custom tag from env, file, or branch
        get_session_tag() {
            local tag=""
            if [[ -n "$BEACON_TAG" ]]; then
                tag="$BEACON_TAG"
            elif [[ -f ".beacon-tag" ]]; then
                tag=$(cat .beacon-tag | head -1 | tr -d '\\n')
            elif git rev-parse --git-dir &>/dev/null; then
                local git_root=$(git rev-parse --show-toplevel 2>/dev/null)
                if [[ -f "${git_root}/.beacon-tag" ]]; then
                    tag=$(cat "${git_root}/.beacon-tag" | head -1 | tr -d '\\n')
                fi
                if [[ -z "$tag" ]]; then
                    local branch=$(git branch --show-current 2>/dev/null)
                    if [[ "$branch" =~ -([a-zA-Z]+)$ ]]; then
                        tag="${BASH_REMATCH[1]}"
                    fi
                fi
            fi
            echo "$tag"
        }

        session_tag=$(get_session_tag)
        [[ -n "$session_tag" ]] && project_identifier="${project_name}-${session_tag}" || project_identifier="$project_name"

        # Pronunciation fixes
        fix_pronunciation() {
            echo "$1" | sed -E '
                s/vitess/vitesse/gi; s/kubectl/cube control/gi; s/nginx/engine x/gi
                s/mysql/my sequel/gi; s/github/git hub/gi; s/-ops/ ops/gi
                s/-api/ A P I/gi; s/-cli/ C L I/gi
            '
        }

        # Generate summary from git activity
        generate_summary() {
            local summary="done"
            if git rev-parse --git-dir &>/dev/null; then
                local last_commit_time=$(git log -1 --format="%ct" 2>/dev/null || echo "0")
                local now=$(date +%s)
                if [[ $((now - last_commit_time)) -lt 300 ]]; then
                    local action=$(git log -1 --format="%s" 2>/dev/null | awk '{print tolower($1)}')
                    case "$action" in
                        fix*) summary="fix" ;; add*) summary="add" ;; update*) summary="update" ;;
                        remove*|delete*) summary="remove" ;; refactor*) summary="refactor" ;;
                        test*) summary="test" ;; doc*) summary="docs" ;; feat*) summary="feature" ;;
                        *) summary="$action" ;;
                    esac
                fi
            fi
            echo "$summary"
        }

        task_summary=$(generate_summary)
        task_details=$(git log -1 --format="%s" 2>/dev/null || echo "")

        # Detect terminal and capture identifiers for window switching
        wezterm_pane=""
        tty_name=""
        pycharm_window=""
        pycharm_tab_name=""
        iterm_session_id=""

        # Get TTY for any terminal (use ps to resolve from parent process since hooks lack a controlling tty)
        tty_name=$(tty 2>/dev/null | sed 's|/dev/||' || echo "")
        if [[ -z "$tty_name" || "$tty_name" == "not a tty" ]]; then
            tty_name=$(ps -p $PPID -o tty= 2>/dev/null | tr -d ' ')
        fi
        if [[ -z "$tty_name" || "$tty_name" == "??" ]]; then
            grandparent=$(ps -p $PPID -o ppid= 2>/dev/null | tr -d ' ')
            tty_name=$(ps -p $grandparent -o tty= 2>/dev/null | tr -d ' ')
        fi

        if [[ -n "$TERMINAL_EMULATOR" ]] && [[ "$TERMINAL_EMULATOR" == *"JetBrains"* ]]; then
            app_name="PyCharm"
            tab_info="PyCharm"
            # Query Beacon plugin for active terminal tab (reliable, works with custom tab names)
            plugin_response=$(curl -s --connect-timeout 1 --max-time 2 http://127.0.0.1:19877/active-terminal 2>/dev/null || echo "")
            if [[ -n "$plugin_response" && "$plugin_response" != "[]" ]]; then
                # Match project by cwd — plugin returns basePath for each project
                plugin_match=$(echo "$plugin_response" | python3 -c "import sys,json;[print(p['project']+'\\\\t'+p['tabName']) for p in json.load(sys.stdin) if '$cwd'.startswith(p.get('basePath','/'))][:1]" 2>/dev/null | head -1)
                if [[ -n "$plugin_match" ]]; then
                    pycharm_window=$(echo "$plugin_match" | cut -f1)
                    pycharm_tab_name=$(echo "$plugin_match" | cut -f2)
                fi
            fi
            # Fallback: get window name via osascript if plugin not available
            if [[ -z "$pycharm_window" ]]; then
                pycharm_window=$(osascript -e 'tell application "System Events" to tell process "pycharm" to get name of front window' 2>/dev/null | cut -d' ' -f1 || echo "")
            fi
        elif [[ -n "$WEZTERM_PANE" ]]; then
            app_name="WezTerm"
            tab_info="WezTerm"
            wezterm_pane="$WEZTERM_PANE"
        elif [[ -n "$ITERM_SESSION_ID" ]]; then
            app_name="iTerm"
            tab_info="iTerm"
            iterm_session_id="$ITERM_SESSION_ID"
        elif [[ "$TERM_PROGRAM" == "vscode" ]] || [[ -n "$VSCODE_INJECTION" ]]; then
            app_name="Cursor"
            tab_info="Cursor"
        elif [[ "$TERM_PROGRAM" == "Apple_Terminal" ]] || [[ -z "$TERM_PROGRAM" ]]; then
            app_name="Terminal"
            tab_info="Terminal"
        else
            app_name="${TERM_PROGRAM:-Terminal}"
            tab_info="${TERM_PROGRAM:-Terminal}"
        fi

        # Send to Beacon with navigation info
        SESSION_ID="$$-$(date +%s)"
        escaped_details=$(echo "$task_details" | sed 's/"/\\\\"/g')
        curl -s -X POST "http://localhost:${BEACON_PORT}" \\
            -H "Content-Type: application/json" \\
            -d "{\\"id\\":\\"${SESSION_ID}\\",\\"projectName\\":\\"${project_identifier}\\",\\"terminalInfo\\":\\"${tab_info}\\",\\"workingDirectory\\":\\"${cwd}\\",\\"summary\\":\\"${task_summary}\\",\\"details\\":\\"${escaped_details}\\",\\"tag\\":\\"${session_tag}\\",\\"weztermPane\\":\\"${wezterm_pane}\\",\\"ttyName\\":\\"${tty_name}\\",\\"pycharmWindow\\":\\"${pycharm_window}\\",\\"pycharmTabName\\":\\"${pycharm_tab_name}\\",\\"itermSessionId\\":\\"${iterm_session_id}\\"}" \\
            --connect-timeout 1 2>/dev/null &
        """
    }

    // MARK: - Settings.json Management

    private func addHookToSettings() -> (success: Bool, message: String) {
        var settings: [String: Any] = [:]

        // Read existing settings if present
        if FileManager.default.fileExists(atPath: settingsFile.path) {
            do {
                let data = try Data(contentsOf: settingsFile)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    settings = json
                }
            } catch {
                // Continue with empty settings
            }
        }

        // Get or create hooks section
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Remove legacy PostToolUse hook if present
        if var postToolUse = hooks["PostToolUse"] as? [[String: Any]] {
            postToolUse.removeAll { hook in
                if let command = hook["command"] as? String {
                    return command.contains("task-complete-alert.sh")
                }
                return false
            }
            if postToolUse.isEmpty {
                hooks.removeValue(forKey: "PostToolUse")
            } else {
                hooks["PostToolUse"] = postToolUse
            }
        }

        // Remove SubagentStop hook to prevent double alerts (Stop already covers it)
        if var subagentStopHooks = hooks["SubagentStop"] as? [[String: Any]] {
            subagentStopHooks.removeAll { entry in
                if let innerHooks = entry["hooks"] as? [[String: Any]] {
                    return innerHooks.contains { hook in
                        if let command = hook["command"] as? String {
                            return command.contains("task-complete-alert.sh")
                        }
                        return false
                    }
                }
                return false
            }
            if subagentStopHooks.isEmpty {
                hooks.removeValue(forKey: "SubagentStop")
            } else {
                hooks["SubagentStop"] = subagentStopHooks
            }
        }

        // Get or create Stop hook array
        var stopHooks = hooks["Stop"] as? [[String: Any]] ?? []

        // Check if our hook already exists
        let hookExists = stopHooks.contains { entry in
            if let innerHooks = entry["hooks"] as? [[String: Any]] {
                return innerHooks.contains { hook in
                    if let command = hook["command"] as? String {
                        return command.contains("task-complete-alert.sh")
                    }
                    return false
                }
            }
            return false
        }

        if !hookExists {
            // Add our hook using the Stop event format
            let newHook: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": "~/.claude/task-complete-alert.sh",
                    "timeout": 10
                ] as [String: Any]]
            ]
            stopHooks.append(newHook)
            hooks["Stop"] = stopHooks
        }

        settings["hooks"] = hooks

        // Always write back to persist any cleanup or additions
        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsFile, options: .atomic)
        } catch {
            return (false, "Failed to update settings.json: \(error.localizedDescription)")
        }

        return (true, "Hook added to settings.json")
    }

    private func removeHookFromSettings() -> (success: Bool, message: String) {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else {
            return (true, "No settings file to update")
        }

        do {
            let data = try Data(contentsOf: settingsFile)
            guard var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (true, "Settings file is empty")
            }

            guard var hooks = settings["hooks"] as? [String: Any] else {
                return (true, "No hooks configured")
            }

            // Remove from Stop hooks
            if var stopHooks = hooks["Stop"] as? [[String: Any]] {
                stopHooks.removeAll { entry in
                    if let innerHooks = entry["hooks"] as? [[String: Any]] {
                        return innerHooks.contains { hook in
                            if let command = hook["command"] as? String {
                                return command.contains("task-complete-alert.sh")
                            }
                            return false
                        }
                    }
                    return false
                }
                if stopHooks.isEmpty {
                    hooks.removeValue(forKey: "Stop")
                } else {
                    hooks["Stop"] = stopHooks
                }
            }

            // Also remove legacy PostToolUse hook if present
            if var postToolUse = hooks["PostToolUse"] as? [[String: Any]] {
                postToolUse.removeAll { hook in
                    if let command = hook["command"] as? String {
                        return command.contains("task-complete-alert.sh")
                    }
                    return false
                }
                if postToolUse.isEmpty {
                    hooks.removeValue(forKey: "PostToolUse")
                } else {
                    hooks["PostToolUse"] = postToolUse
                }
            }

            settings["hooks"] = hooks

            // Write back
            let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try newData.write(to: settingsFile, options: .atomic)

            return (true, "Hook removed from settings.json")
        } catch {
            return (false, "Failed to update settings.json: \(error.localizedDescription)")
        }
    }
}
