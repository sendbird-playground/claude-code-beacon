#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LAUNCHAGENT_PLIST="$HOME/Library/LaunchAgents/com.sendbird.Beacon.plist"
LAUNCHAGENT_LABEL="com.sendbird.Beacon"

# Build app using build.sh
./build.sh

echo ""
echo "Signing app bundle..."
# Ad-hoc sign with hardened runtime for notification permissions
codesign --force --deep --sign - --entitlements /dev/stdin build/Beacon.app << 'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
ENTITLEMENTS

# Stop existing LaunchAgent if running
if launchctl list | grep -q "$LAUNCHAGENT_LABEL"; then
    echo "Stopping existing Beacon service..."
    launchctl unload "$LAUNCHAGENT_PLIST" 2>/dev/null || true
fi

# Also kill any running Beacon process
pkill -x Beacon 2>/dev/null || true
sleep 1

echo "Installing to /Applications..."
rm -rf /Applications/Beacon.app
cp -r build/Beacon.app /Applications/

# Re-sign after copy to ensure signature is intact
codesign --force --deep --sign - /Applications/Beacon.app

# Install LaunchAgent for auto-restart
echo "Installing LaunchAgent for auto-restart..."
mkdir -p "$HOME/Library/LaunchAgents"
cp "Resources/com.sendbird.Beacon.plist" "$LAUNCHAGENT_PLIST"

# Load the LaunchAgent (will start Beacon automatically)
echo "Starting Beacon service..."
launchctl load "$LAUNCHAGENT_PLIST"

echo ""
echo "Done! Beacon has been installed to /Applications"
echo ""
echo "Beacon is now running as a persistent service:"
echo "  - Starts automatically at login"
echo "  - Restarts automatically if quit or crashed"
echo ""
echo "To uninstall the auto-restart service:"
echo "  ./uninstall.sh"
