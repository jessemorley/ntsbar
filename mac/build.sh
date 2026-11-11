#!/bin/sh
# Builds NTSBar.app (menu bar only, no Dock icon) next to this script.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=NTSBar.app/Contents
mkdir -p "$APP/MacOS"
rm -f "$APP/MacOS/NTSBar"  # overwriting in place while running makes macOS SIGKILL the new copy
cp .build/release/NTSBar "$APP/MacOS/"
mkdir -p "$APP/Resources"
# Icon Composer icon -> Assets.car (Liquid Glass) + NTSBar.icns fallback
xcrun actool NTSBar.icon --compile "$APP/Resources" --app-icon NTSBar --platform macosx \
  --minimum-deployment-target 27.0 --output-partial-info-plist /dev/null >/dev/null
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>NTSBar</string>
  <key>CFBundleIdentifier</key><string>com.jessemorley.ntsbar</string>
  <key>CFBundleName</key><string>NTS</string>
  <key>CFBundleIconFile</key><string>NTSBar</string>
  <key>CFBundleIconName</key><string>NTSBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
</dict></plist>
PLIST
# Stable signature so the keychain item's ACL survives rebuilds (ad-hoc cdhash changes every build)
codesign --force --sign "Apple Development" --identifier com.jessemorley.ntsbar NTSBar.app
echo "Built $(pwd)/NTSBar.app"
