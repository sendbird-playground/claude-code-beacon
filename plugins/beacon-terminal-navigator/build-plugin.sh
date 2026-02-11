#!/bin/bash
set -e

cd "$(dirname "$0")"
echo "Building Beacon Terminal Navigator plugin..."
./gradlew buildPlugin

ZIP=$(ls -1 build/distributions/*.zip 2>/dev/null | head -1)
if [[ -n "$ZIP" ]]; then
    echo ""
    echo "Plugin built successfully:"
    echo "  $ZIP"
    echo ""
    echo "Install in PyCharm: Settings → Plugins → ⚙ → Install Plugin from Disk → select the zip"
else
    echo "Build failed — no zip found in build/distributions/"
    exit 1
fi
