#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

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

echo "Installing to /Applications..."
rm -rf /Applications/Beacon.app
cp -r build/Beacon.app /Applications/

# Re-sign after copy to ensure signature is intact
codesign --force --deep --sign - /Applications/Beacon.app

echo ""
echo "Done! Beacon has been installed to /Applications"
echo ""
echo "To start Beacon:"
echo "  open /Applications/Beacon.app"
echo ""
echo "To start at login, add Beacon to:"
echo "  System Settings → General → Login Items"
