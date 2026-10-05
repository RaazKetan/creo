#!/bin/zsh
# curl -fsSL https://raw.githubusercontent.com/RaazKetan/creo/main/install.sh | zsh
set -e

REPO="https://github.com/RaazKetan/creo.git"
WORK="${TMPDIR:-/tmp}/creo-install"

command -v swift >/dev/null || {
  echo "Needs the Xcode Command Line Tools. Run: xcode-select --install"
  exit 1
}

echo "Building Creo…"
rm -rf "$WORK"
git clone -q --depth 1 "$REPO" "$WORK"
cd "$WORK"
./build.sh >/dev/null

pkill -f "ClaudeSessions.app/Contents/MacOS" 2>/dev/null || true
pkill -f "Creo.app/Contents/MacOS" 2>/dev/null || true
rm -rf /Applications/ClaudeSessions.app /Applications/Creo.app
cp -R Creo.app /Applications/
cd - >/dev/null && rm -rf "$WORK"

open /Applications/Creo.app
echo "Installed. Look for the Creo icon in your menu bar."
