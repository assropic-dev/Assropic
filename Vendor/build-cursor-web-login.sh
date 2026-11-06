#!/bin/bash
set -euo pipefail

VENDOR_DIR="$(cd "$(dirname "$0")" && pwd)"
CURSOR_BUILD_DIR="$(mktemp -d -t bridgedock-cursor-build)"
CURSOR_SOURCE_DIR="$CURSOR_BUILD_DIR/source"
CURSOR_COMMIT="75a9770b06f6eeba3f1cdd8da12a7a9fa5c8987d"
CURSOR_ARCHIVE_SHA="a3ec72c5184dab13ce772b2992845edf0eeb57a61559e8342090b2e3a07888ad"

curl --fail --location --retry 3 \
  "https://codeload.github.com/enderzcx/cursor-agent2api/tar.gz/$CURSOR_COMMIT" \
  -o "$CURSOR_BUILD_DIR/upstream.tar.gz"
printf '%s  %s\n' "$CURSOR_ARCHIVE_SHA" "$CURSOR_BUILD_DIR/upstream.tar.gz" | shasum -a 256 -c -
mkdir "$CURSOR_SOURCE_DIR"
tar -xzf "$CURSOR_BUILD_DIR/upstream.tar.gz" -C "$CURSOR_SOURCE_DIR" --strip-components=1
cd "$CURSOR_SOURCE_DIR"
patch -p1 < "$VENDOR_DIR/CursorWebLogin.patch"
patch -p1 < "$VENDOR_DIR/CursorSessionLogin.patch"
patch -p1 < "$VENDOR_DIR/CursorToolCatalog.patch"
go test ./internal/plugin ./cursoragentv1
CGO_ENABLED=1 MACOSX_DEPLOYMENT_TARGET=14.0 go build -trimpath -buildmode=c-shared \
  -o "$CURSOR_BUILD_DIR/cursor-agent2api.dylib" ./cmd/cursor-agent2api
cp "$CURSOR_BUILD_DIR/cursor-agent2api.dylib" "$VENDOR_DIR/cursor-agent2api.dylib.new"
mv "$VENDOR_DIR/cursor-agent2api.dylib.new" "$VENDOR_DIR/cursor-agent2api.dylib"
printf 'Built %s\nSource and test output retained in %s\n' "$VENDOR_DIR/cursor-agent2api.dylib" "$CURSOR_BUILD_DIR"
