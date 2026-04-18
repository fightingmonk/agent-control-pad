#!/bin/bash
set -e

APP_NAME="AgentRemote"
BUNDLE_ID="com.tappister.agentremote"
VERSION=$(cat VERSION)
APP_DIR="$APP_NAME.app/Contents"

echo "Building…"
swift build -c release

echo "Creating app bundle…"
rm -rf "$APP_NAME.app"
mkdir -p "$APP_DIR/MacOS"

cp ".build/release/$APP_NAME" "$APP_DIR/MacOS/$APP_NAME"

cat > "$APP_DIR/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AgentRemote</string>
    <key>CFBundleIdentifier</key>
    <string>com.tappister.agentremote</string>
    <key>CFBundleName</key>
    <string>Agent Remote</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "Done → $APP_NAME.app"
echo ""
echo "To install:"
echo "  cp -r $APP_NAME.app /Applications/"
echo "  open /Applications/$APP_NAME.app"
