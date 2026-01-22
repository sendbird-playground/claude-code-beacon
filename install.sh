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

echo "Installing to /Applications..."
rm -rf /Applications/Beacon.app
cp -r Beacon.app /Applications/

echo "Done! Beacon has been installed to /Applications"
echo ""
echo "To start Beacon:"
echo "  open /Applications/Beacon.app"
echo ""
echo "To start at login, add Beacon to:"
echo "  System Settings → General → Login Items"
