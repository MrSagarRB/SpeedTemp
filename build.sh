#!/bin/zsh
# Builds SpeedTemp.app next to this script.
set -e
cd "$(dirname "$0")"

APP="SpeedTemp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Universal binary: runs on Apple Silicon and Intel Macs.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13.0 main.swift -o "/tmp/SpeedTemp-$arch" \
    -framework Cocoa -framework IOKit -framework ServiceManagement
done
lipo -create /tmp/SpeedTemp-arm64 /tmp/SpeedTemp-x86_64 -output "$APP/Contents/MacOS/SpeedTemp"
rm /tmp/SpeedTemp-arm64 /tmp/SpeedTemp-x86_64

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SpeedTemp</string>
  <key>CFBundleDisplayName</key><string>SpeedTemp</string>
  <key>CFBundleIdentifier</key><string>local.speedtemp</string>
  <key>CFBundleExecutable</key><string>SpeedTemp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
