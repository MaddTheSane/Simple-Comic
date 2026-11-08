#!/bin/bash
# Installs the notarized build/export/Simple Comic.app into /Applications,
# replacing any existing copy. Quits a running instance first (matched by
# bundle path, never a Debug/DerivedData build).
#
# Note: an existing /Applications/Simple Comic.app installed from the Mac
# App Store is typically root-owned, so replacing it needs sudo. This
# script uses sudo unconditionally for the destination write so it behaves
# the same whether or not an App Store copy is already there. Replacing an
# App Store install this way means macOS/the App Store will still think
# the App Store version is installed and may reinstall over this build on
# a future update check.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

src_app="build/export/Simple Comic.app"
dest_app="/Applications/Simple Comic.app"

if [[ ! -d "$src_app" ]]; then
  echo "error: $src_app not found — run scripts/build_release.sh (+ notarize.sh) first" >&2
  exit 1
fi

if pgrep -f "${dest_app}/Contents/MacOS/Simple Comic" >/dev/null 2>&1; then
  echo "==> quitting running /Applications instance"
  osascript -e 'tell application "Simple Comic" to quit' 2>/dev/null || true
  pkill -f "${dest_app}/Contents/MacOS/Simple Comic" 2>/dev/null || true
  sleep 1
fi

echo "==> installing to $dest_app"
sudo rm -rf "$dest_app"
sudo ditto "$src_app" "$dest_app"
sudo chown -R "$(id -u):$(id -g)" "$dest_app"

echo "==> installed: $dest_app"
