#!/bin/bash
# Notarizes and staples the exported .app, then zips the stapled app into
# dist/Simple.Comic.<version>.zip, the artifact attached to the GitHub release
# (dot separator matches the name GitHub gives the asset, and past releases).
#
# The App Store Connect API key is pulled live from 1Password on every run
# (see scripts/lib.sh).
#
# Usage: scripts/notarize.sh <version>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$repo_root"

version="${1:?usage: notarize.sh <version>}"
app_path="build/export/$APP_NAME.app"
submit_zip="build/notarize-submission.zip"
dist_zip="dist/Simple.Comic.${version}.zip"

if [[ ! -d "$app_path" ]]; then
  echo "error: $app_path not found — run scripts/build_release.sh first" >&2
  exit 1
fi

echo "==> fetching App Store Connect API key from 1Password"
asc_key_setup

echo "==> zipping for submission"
rm -f "$submit_zip"
ditto -c -k --keepParent "$app_path" "$submit_zip"

echo "==> submitting to notarytool (key id: $ASC_KEY_ID)"
xcrun notarytool submit "$submit_zip" \
  --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait

echo "==> stapling ticket"
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose "$app_path"

echo "==> zipping stapled app for release"
mkdir -p dist
rm -f "$dist_zip"
# --norsrc/--noextattr/--noqtn/--noacl keep AppleDouble "._*" entries out of the
# zip: plain unzip / Archive Utility extract them as real files inside the
# bundle, which breaks the code-signature seal ("app is damaged").
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$app_path" "$dist_zip"
if unzip -l "$dist_zip" | grep -q '/\._'; then
  echo "error: $dist_zip contains AppleDouble (._*) entries" >&2
  exit 1
fi
echo "==> notarized artifact: $dist_zip"
