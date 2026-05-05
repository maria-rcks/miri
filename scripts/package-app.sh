#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${MIRI_VERSION:-0.1.0-dev}"
BUILD_NUMBER="${MIRI_BUILD_NUMBER:-1}"
OUTPUT_DIR="${MIRI_OUTPUT_DIR:-dist}"

cd "$ROOT_DIR"

scripts/package-macos.sh \
  --version "$VERSION" \
  --build-number "$BUILD_NUMBER" \
  --output-dir "$OUTPUT_DIR" \
  --keep-stage

STAGED_APP="$ROOT_DIR/$OUTPUT_DIR/stage/arm64-darwin/volume/Miri.app"
APP_DIR="$ROOT_DIR/$OUTPUT_DIR/Miri.app"

rm -rf "$APP_DIR"
cp -R "$STAGED_APP" "$APP_DIR"

# Keep package-app.sh compatible with the old local-dev workflow: leave a directly
# openable .app at dist/Miri.app, while package-macos.sh also creates the DMG.
echo "Packaged $APP_DIR"
echo "Launch with: open '$APP_DIR'"
