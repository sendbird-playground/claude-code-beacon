#!/bin/bash

# Build script for Beacon
# Creates a proper macOS app bundle and optionally a pkg installer

set -e

APP_NAME="Beacon"
BUNDLE_NAME="Beacon.app"
EXECUTABLE_NAME="Beacon"
BUNDLE_ID="com.sendbird.Beacon"
VERSION=$(grep -o '"[0-9]\+\.[0-9]\+\.[0-9]\+"' Sources/Beacon/Version.swift | tr -d '"')
BUILD_DIR=".build/release"
OUTPUT_DIR="build"
PKG_NAME="Beacon-$VERSION.pkg"

# Parse arguments
BUILD_PKG=false
for arg in "$@"; do
    case $arg in
        --pkg)
            BUILD_PKG=true
            shift
            ;;
    esac
done

echo "Building $APP_NAME v$VERSION..."

# Build release version
swift build -c release

# Create app bundle structure
mkdir -p "$OUTPUT_DIR/$BUNDLE_NAME/Contents/MacOS"
mkdir -p "$OUTPUT_DIR/$BUNDLE_NAME/Contents/Resources"

# Copy executable
cp "$BUILD_DIR/$EXECUTABLE_NAME" "$OUTPUT_DIR/$BUNDLE_NAME/Contents/MacOS/"

# Create Info.plist
cat > "$OUTPUT_DIR/$BUNDLE_NAME/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Copy app icon if exists
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$OUTPUT_DIR/$BUNDLE_NAME/Contents/Resources/"
fi

# Create PkgInfo
echo -n "APPL????" > "$OUTPUT_DIR/$BUNDLE_NAME/Contents/PkgInfo"

echo ""
echo "Build complete!"
echo "App bundle created at: $OUTPUT_DIR/$BUNDLE_NAME"

# Build pkg installer if requested
if [ "$BUILD_PKG" = true ]; then
    echo ""
    echo "Creating pkg installer..."

    # Create a temporary directory for pkg build
    PKG_ROOT="$OUTPUT_DIR/pkg-root"
    rm -rf "$PKG_ROOT"
    mkdir -p "$PKG_ROOT/Applications"

    # Copy app bundle to pkg root
    cp -r "$OUTPUT_DIR/$BUNDLE_NAME" "$PKG_ROOT/Applications/"

    # Build the component package
    pkgbuild \
        --root "$PKG_ROOT" \
        --identifier "$BUNDLE_ID" \
        --version "$VERSION" \
        --install-location "/" \
        "$OUTPUT_DIR/$PKG_NAME"

    # Clean up
    rm -rf "$PKG_ROOT"

    echo ""
    echo "Pkg installer created at: $OUTPUT_DIR/$PKG_NAME"
    echo ""
    echo "To install:"
    echo "  open $OUTPUT_DIR/$PKG_NAME"
else
    echo ""
    echo "To run the app:"
    echo "  open $OUTPUT_DIR/$BUNDLE_NAME"
    echo ""
    echo "To install to Applications:"
    echo "  cp -r $OUTPUT_DIR/$BUNDLE_NAME /Applications/"
    echo ""
    echo "To create a pkg installer:"
    echo "  ./build.sh --pkg"
fi
