#!/usr/bin/env bash
# Builds PiSandbox.app (ad-hoc signed) and a shareable zip. Needs only Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
APP=dist/PiSandbox.app

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/PiSandbox"

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/seed/agent-home"
cp "$BIN" "$APP/Contents/MacOS/PiSandbox"
cp "$ROOT/Dockerfile" "$APP/Contents/Resources/seed/"
cp "$ROOT/agent-home/AGENTS.md" "$APP/Contents/Resources/seed/agent-home/"
cp -R "$ROOT/agent-home/skills" "$APP/Contents/Resources/seed/agent-home/"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Pi Sandbox</string>
  <key>CFBundleDisplayName</key><string>Pi Sandbox</string>
  <key>CFBundleIdentifier</key><string>com.rolemodel.pisandbox</string>
  <key>CFBundleExecutable</key><string>PiSandbox</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PL

codesign --force --deep --sign - "$APP"
ditto -c -k --keepParent "$APP" dist/PiSandbox.zip
echo "Built $APP and dist/PiSandbox.zip"
