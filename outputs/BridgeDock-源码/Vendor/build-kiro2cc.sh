#!/bin/bash
set -euo pipefail

VENDOR_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(mktemp -d -t bridgedock-kiro2cc-build)"
SOURCE_DIR="$BUILD_DIR/source"
COMMIT="e5387453c10a87e350fbe2d7c6505a1b128f5445"
ARCHIVE_SHA="b2e35fd35b9daeaffaa290298d4d64c18cb00387631868eee4745c9218200ec9"

curl --fail --location --retry 3 \
  "https://codeload.github.com/TsinHzl/kiro2cc-proxy/tar.gz/$COMMIT" \
  -o "$BUILD_DIR/upstream.tar.gz"
printf '%s  %s\n' "$ARCHIVE_SHA" "$BUILD_DIR/upstream.tar.gz" | shasum -a 256 -c -
mkdir "$SOURCE_DIR"
tar -xzf "$BUILD_DIR/upstream.tar.gz" -C "$SOURCE_DIR" --strip-components=1
cd "$SOURCE_DIR"
# Kiro Free accounts can call Opus too (model-aware routing decides, not the plan name);
# reasoning_effort also accepts xhigh and max.
patch -p1 < "$VENDOR_DIR/Kiro2ccFreeOpus.patch"
# BridgeDock drives the admin API directly; the embedded web consoles stay empty.
for ui in admin-ui user-ui; do
  mkdir -p "web-ui/$ui/dist"
  printf '<!doctype html><title>BridgeDock</title>\n' > "web-ui/$ui/dist/index.html"
done
# This upstream test indexes records by position although same-nanosecond
# timestamps make that order unstable (see its own comment); it fails intermittently.
cargo test --release --locked -- --skip test_record_effort_persisted_and_none_fallback
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --release --locked
cp target/release/kiro2cc-proxy "$VENDOR_DIR/kiro2cc-proxy.new"
mv "$VENDOR_DIR/kiro2cc-proxy.new" "$VENDOR_DIR/kiro2cc-proxy"
cp LICENSE "$VENDOR_DIR/Kiro2cc-LICENSE"
printf 'Built %s\nSource and test output retained in %s\n' "$VENDOR_DIR/kiro2cc-proxy" "$BUILD_DIR"
