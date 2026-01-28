#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building Beacon..."
swift build -c release

echo "Creating app bundle..."
rm -rf Beacon.app
mkdir -p Beacon.app/Contents/MacOS
mkdir -p Beacon.app/Contents/Resources
cp .build/release/Beacon Beacon.app/Contents/MacOS/
cp Resources/Info.plist Beacon.app/Contents/
cp Resources/AppIcon.icns Beacon.app/Contents/Resources/

echo "Signing app bundle..."
# Ad-hoc sign with hardened runtime for notification permissions
codesign --force --deep --sign - --entitlements /dev/stdin Beacon.app << 'ENTITLEMENTS'
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
cp -r Beacon.app /Applications/

# Re-sign after copy to ensure signature is intact
codesign --force --deep --sign - /Applications/Beacon.app

echo "Done! Beacon has been installed to /Applications"
echo ""
echo "To start Beacon:"
echo "  open /Applications/Beacon.app"
echo ""
echo "To start at login, add Beacon to:"
echo "  System Settings → General → Login Items"
