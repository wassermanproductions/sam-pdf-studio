#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="SamPDFStudio"
BUNDLE_ID="com.sam.private.SamPDFStudio"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
VENV_DIR="${SAMPDF_VENV_DIR:-$HOME/Library/Application Support/SamPDFStudio/engine-venv}"
ENGINE_PYTHON="$VENV_DIR/bin/python3"
ENGINE_SCRIPT="$ROOT_DIR/Engine/pdf_engine.py"

if [[ ! -x "$ENGINE_PYTHON" ]]; then
  "$ROOT_DIR/script/bootstrap_engine.sh"
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

SCRATCH_DIR="${SAMPDF_SCRATCH_DIR:-$HOME/Library/Caches/SamPDFStudio/build}"
swift build --scratch-path "$SCRATCH_DIR"
BUILD_BINARY="$(swift build --scratch-path "$SCRATCH_DIR" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_CONTENTS/Resources"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

# Bundle the engine script inside the app. At runtime nothing may live in
# TCC-protected folders (Documents/Desktop): a fresh ad-hoc-signed build
# would hang on a folder-permission prompt when spawning the engine.
cp "$ROOT_DIR/Engine/pdf_engine.py" "$APP_CONTENTS/Resources/pdf_engine.py"
ENGINE_SCRIPT="$APP_CONTENTS/Resources/pdf_engine.py"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Sam PDF Studio</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>SamPDFProjectRoot</key>
  <string>$ROOT_DIR</string>
  <key>SamPDFEnginePythonPath</key>
  <string>$ENGINE_PYTHON</string>
  <key>SamPDFEngineScriptPath</key>
  <string>$ENGINE_SCRIPT</string>
  <key>SamPDFBuildTime</key>
  <string>$(date '+%b %-d %-I:%M %p')</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
