#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="${1:-../BridgeDock.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 Sources/*.swift \
  -o "$APP/Contents/MacOS/BridgeDock" -framework SwiftUI -framework AppKit -framework CryptoKit
cp Vendor/cli-proxy-api Vendor/kiro.dylib "$APP/Contents/Resources/"
cp Vendor/*LICENSE "$APP/Contents/Resources/"
if [ -f Resources/BridgeDock.icns ]; then
  cp Resources/BridgeDock.icns "$APP/Contents/Resources/"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.bridgedock.app</string>
<key>CFBundleName</key><string>BridgeDock</string>
<key>CFBundleDisplayName</key><string>BridgeDock 桥接台</string>
<key>CFBundleExecutable</key><string>BridgeDock</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>BridgeDock</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Resources/kiro.dylib"
codesign --force --sign - "$APP/Contents/Resources/cli-proxy-api"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
