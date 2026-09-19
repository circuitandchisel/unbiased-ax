#!/bin/bash
# Builds ProbeTarget.app (a real bundle, so it can be named, activated and
# reached by AppleEvents the way an agent reaches any app) and the recorder.
set -euo pipefail
cd "$(dirname "$0")"
OUT="build"
APP="$OUT/ProbeTarget.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ProbeTarget</string>
  <key>CFBundleDisplayName</key><string>ProbeTarget</string>
  <key>CFBundleExecutable</key><string>ProbeTarget</string>
  <key>CFBundleIdentifier</key><string>ai.unbiased.cuaprobe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

swiftc -O -o "$APP/Contents/MacOS/ProbeTarget" ProbeTarget.swift
swiftc -O -o "$OUT/recorder" recorder.swift
# Ad-hoc signed with a stable identity so macOS keeps whatever permissions are
# granted to it across rebuilds, the same reason the bridge pins its own.
codesign --force --sign - --identifier ai.unbiased.cuaprobe \
  --requirements '=designated => identifier "ai.unbiased.cuaprobe"' "$APP" >/dev/null 2>&1 || true
codesign --force --sign - "$OUT/recorder" >/dev/null 2>&1 || true

echo "built $APP and $OUT/recorder"
