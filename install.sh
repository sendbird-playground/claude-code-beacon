#!/bin/bash
set -e

echo "Building Beacon..."
swift build -c release

echo "Creating app bundle..."
mkdir -p Beacon.app/Contents/MacOS
cp .build/release/Beacon Beacon.app/Contents/MacOS/

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
