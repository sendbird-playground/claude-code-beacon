#!/bin/bash
set -e

LAUNCHAGENT_PLIST="$HOME/Library/LaunchAgents/com.sendbird.Beacon.plist"
LAUNCHAGENT_LABEL="com.sendbird.Beacon"

echo "Uninstalling Beacon..."

# Stop and unload LaunchAgent
if [ -f "$LAUNCHAGENT_PLIST" ]; then
    echo "Stopping Beacon service..."
    launchctl unload "$LAUNCHAGENT_PLIST" 2>/dev/null || true
    rm -f "$LAUNCHAGENT_PLIST"
    echo "LaunchAgent removed"
fi

# Kill any running Beacon process
pkill -x Beacon 2>/dev/null || true

# Remove app from Applications
if [ -d "/Applications/Beacon.app" ]; then
    echo "Removing /Applications/Beacon.app..."
    rm -rf /Applications/Beacon.app
fi

# Optionally remove data (ask user)
echo ""
read -p "Remove Beacon data (sessions, settings)? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "$HOME/Library/Application Support/Beacon"
    echo "Data removed"
fi

echo ""
echo "Beacon has been uninstalled"
