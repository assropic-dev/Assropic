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
cp Vendor/cli-proxy-api Vendor/*.dylib "$STAGE/Contents/Resources/"
cp Vendor/*LICENSE "$STAGE/Contents/Resources/"
cp Vendor/*NOTICE* "$STAGE/Contents/Resources/"
cp -R Resources/CursorLocal Resources/AgentIcons "$STAGE/Contents/Resources/"
# Cursor 中文补丁，源文件在项目根目录的 cursor-zh/。语言包原包必须已经下载好。
[ -f ../../cursor-zh/vendor/cursor-language-pack-1.1.3.tgz ] || { echo "缺少 cursor-zh/vendor 里的语言包，先运行一次 cursor-zh/install.sh" >&2; exit 1; }
ditto --norsrc --noextattr ../../cursor-zh "$STAGE/Contents/Resources/CursorZh"
find "$STAGE/Contents/Resources/CursorZh" -name '._*' -delete
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
<key>CFBundleShortVersionString</key><string>1.4.11</string>
<key>CFBundleVersion</key><string>22</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${BRIDGEDOCK_VERSION:-1.4.11}" "$STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BRIDGEDOCK_BUILD:-22}" "$STAGE/Contents/Info.plist"
find "$STAGE" -name '._*' -delete
xattr -cr "$STAGE"
for library in "$STAGE/Contents/Resources/"*.dylib; do
  codesign --force --sign - "$library"
done
codesign --force --sign - "$STAGE/Contents/Resources/cli-proxy-api"
codesign --force --deep --sign - "$STAGE"
codesign --verify --deep --strict "$STAGE"

rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$ZIP"
rm -rf "$APP"
ditto --norsrc --noextattr "$STAGE" "$APP"
echo "Built $APP"
echo "Packed $ZIP"
