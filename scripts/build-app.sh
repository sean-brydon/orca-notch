#!/bin/sh
# Builds OrcaNotch.app (release) and installs it to ~/Applications.
set -eu
cd "$(dirname "$0")/.."

swift build -c release
APP="build/OrcaNotch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/OrcaNotch "$APP/Contents/MacOS/OrcaNotch"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Orca Notch</string>
  <key>CFBundleIdentifier</key><string>dev.sean.orca-notch</string>
  <key>CFBundleExecutable</key><string>OrcaNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"

if [ "${1:-}" != "--no-install" ]; then
  mkdir -p "$HOME/Applications"
  pkill -x OrcaNotch 2>/dev/null || true
  rm -rf "$HOME/Applications/OrcaNotch.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/OrcaNotch.app"
  echo "Installed and launched ~/Applications/OrcaNotch.app"
fi
