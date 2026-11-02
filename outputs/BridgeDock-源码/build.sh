#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="${1:-../BridgeDock.app}"
case "$APP" in *.app) ;; *) echo "App path must end with .app" >&2; exit 1 ;; esac
ZIP="$(dirname "$APP")/BridgeDock-macOS-arm64.zip"

# Build and sign on the local disk. exFAT/FAT drives store extended attributes
# as ._ files, which break the code signature and leak into the zip.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/BridgeDock.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
# SWIFT_EXTRA_FLAGS lets sandboxed shells pass -disable-sandbox.
xcrun swiftc ${SWIFT_EXTRA_FLAGS:-} -O -swift-version 5 -target arm64-apple-macosx14.0 Sources/*.swift \
  -o "$STAGE/Contents/MacOS/BridgeDock" -framework SwiftUI -framework AppKit -framework CryptoKit
cp Vendor/cli-proxy-api Vendor/kiro.dylib "$STAGE/Contents/Resources/"
cp Vendor/*LICENSE "$STAGE/Contents/Resources/"
if [ -f Resources/BridgeDock.icns ]; then
  cp Resources/BridgeDock.icns "$STAGE/Contents/Resources/"
fi
cat > "$STAGE/Contents/Info.plist" <<'PLIST'
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
find "$STAGE" -name '._*' -delete
xattr -cr "$STAGE"
codesign --force --sign - "$STAGE/Contents/Resources/kiro.dylib"
codesign --force --sign - "$STAGE/Contents/Resources/cli-proxy-api"
codesign --force --deep --sign - "$STAGE"
codesign --verify --deep --strict "$STAGE"

rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$ZIP"
rm -rf "$APP"
ditto --norsrc --noextattr "$STAGE" "$APP"
echo "Built $APP"
echo "Packed $ZIP"
