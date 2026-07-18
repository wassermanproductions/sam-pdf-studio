#!/usr/bin/env bash
# Sam PDF Studio macOS installer
#
# Downloads the latest release and installs it to /Applications, bypassing
# the Gatekeeper "app is damaged" false alarm that macOS shows for
# browser-downloaded unsigned apps (terminal downloads aren't quarantined).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wassermanproductions/sam-pdf-studio/main/install.sh | bash
set -euo pipefail

REPO="wassermanproductions/sam-pdf-studio"

if [ "$(uname -m)" != "arm64" ]; then
  echo "Sam PDF Studio currently ships for Apple Silicon (M1–M4) only." >&2
  echo "On Intel Macs, build from source — see the README." >&2
  exit 1
fi

echo "Finding the latest Sam PDF Studio release..."
URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o 'https://[^"]*arm64\.dmg' | head -1)"
if [ -z "$URL" ]; then
  echo "Could not find a macOS download — see https://github.com/$REPO/releases" >&2
  exit 1
fi

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Sam PDF Studio..."
curl -fL --progress-bar "$URL" -o "$TMP/sam-pdf-studio.dmg"

echo "Installing to $DEST..."
MNT="$(hdiutil attach "$TMP/sam-pdf-studio.dmg" -nobrowse | awk -F'\t' '/\/Volumes\//{print $3; exit}')"
rm -rf "$DEST/SamPDFStudio.app"
ditto "$MNT/SamPDFStudio.app" "$DEST/SamPDFStudio.app"
hdiutil detach "$MNT" -quiet
xattr -cr "$DEST/SamPDFStudio.app" 2>/dev/null || true

echo "✓ Sam PDF Studio installed — launching."
open "$DEST/SamPDFStudio.app"
