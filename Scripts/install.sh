#!/usr/bin/env bash
# Install ChacharApp.app into /Applications so it launches without the terminal
# (Spotlight, Finder, Dock). Usage: Scripts/install.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
# Install under the dev name so it can coexist with the notarized distribution build, which owns
# /Applications/ChacharApp.app (they are different apps to TCC — distinct bundle ids).
DEST="/Applications/ChacharApp (dev).app"

# Build + sign the bundle (stable identity → TCC grants persist across installs).
"$ROOT/Scripts/make-app.sh" "$CONFIG"
SRC="$ROOT/.build/ChacharApp.app"

echo "Quitting any running instance…"
pkill -x chacharapp 2>/dev/null || true

echo "Installing to $DEST …"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo ""
echo "Installed: $DEST"
echo "Launch it from Spotlight (⌘Space → \"ChacharApp (dev)\"), Finder, or the Dock."
echo "Note: the installed app links to the model in this repo ($ROOT/Models),"
echo "so keep the repo in place. Re-run this script after code changes."
