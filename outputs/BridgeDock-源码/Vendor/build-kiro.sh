#!/bin/bash
set -euo pipefail

VENDOR_DIR="$(cd "$(dirname "$0")" && pwd)"
KIRO_BUILD_DIR="$(mktemp -d -t bridgedock-kiro-build)"
KIRO_SOURCE_DIR="$KIRO_BUILD_DIR/source"
KIRO_TAG="v0.1.1"
KIRO_ARCHIVE_SHA="45976ae75f3147e3430f44cef9d85bbe6f75476e2e467ffe77542591d6722048"

curl --fail --location --retry 3 \
  "https://codeload.github.com/xiaokui-dev/cliproxyapi-kiro-plugin/tar.gz/refs/tags/$KIRO_TAG" \
  -o "$KIRO_BUILD_DIR/upstream.tar.gz"
printf '%s  %s\n' "$KIRO_ARCHIVE_SHA" "$KIRO_BUILD_DIR/upstream.tar.gz" | shasum -a 256 -c -
mkdir "$KIRO_SOURCE_DIR"
tar -xzf "$KIRO_BUILD_DIR/upstream.tar.gz" -C "$KIRO_SOURCE_DIR" --strip-components=1
cd "$KIRO_SOURCE_DIR"
patch -p1 < "$VENDOR_DIR/KiroStreamChunks.patch"
go test ./...
CGO_ENABLED=1 MACOSX_DEPLOYMENT_TARGET=14.0 go build -trimpath -buildmode=c-shared \
  -o "$KIRO_BUILD_DIR/kiro.dylib" .
cp "$KIRO_BUILD_DIR/kiro.dylib" "$VENDOR_DIR/kiro.dylib.new"
mv "$VENDOR_DIR/kiro.dylib.new" "$VENDOR_DIR/kiro.dylib"
printf 'Built %s\nSource and test output retained in %s\n' "$VENDOR_DIR/kiro.dylib" "$KIRO_BUILD_DIR"
