#!/bin/bash
# Verifies a notarized release zip: extracts it with both ditto and plain unzip
# (they behave differently around AppleDouble files) and checks the signature,
# Gatekeeper assessment, stapled ticket, and that the app and every embedded
# extension report the expected version/build.
#
# Usage: scripts/verify_release.sh <zip> <version> <build>
set -euo pipefail
zip="${1:?usage: verify_release.sh <zip> <version> <build>}"
version="${2:?}"; build="${3:?}"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

check_app() {
  local app="$1" label="$2"
  echo "==> [$label] codesign / spctl / stapler"
  codesign --verify --deep --strict "$app"
  spctl --assess --type execute --verbose "$app"
  xcrun stapler validate "$app"
  local plist
  for plist in "$app/Contents/Info.plist" "$app"/Contents/PlugIns/*/Contents/Info.plist; do
    [[ -f "$plist" ]] || continue
    local v b
    v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
    b=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
    if [[ "$v" != "$version" || "$b" != "$build" ]]; then
      echo "error: ${plist#$app/} reports $v ($b), expected $version ($build)" >&2
      exit 1
    fi
    echo "    ${plist#$app/}: $v ($b)"
  done
}

mkdir "$work/ditto" "$work/unzip"
ditto -x -k "$zip" "$work/ditto"
unzip -q "$zip" -d "$work/unzip"
check_app "$work/ditto/Simple Comic.app" "ditto"
check_app "$work/unzip/Simple Comic.app" "unzip"
echo "==> verified $zip"
