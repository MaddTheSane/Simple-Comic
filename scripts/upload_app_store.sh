#!/bin/bash
# Archives the Release build and uploads it to App Store Connect, signing with
# cloud-managed distribution certs via the App Store Connect API key (no Apple
# ID needs to be signed into Xcode).
#
# Usage: scripts/upload_app_store.sh [export|upload]   (default: upload)
#   export  dry run: produces build/appstore-export/*.pkg locally, uploads nothing
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$repo_root"

mode="${1:-upload}"
archive_path="build/SimpleComic-AppStore.xcarchive"
export_path="build/appstore-export"
asc_key_setup

auth=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "==> archiving for the App Store"
rm -rf "$archive_path"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release clean archive \
  -archivePath "$archive_path" "${auth[@]}"

opts="scripts/ExportOptions-AppStore.plist"
if [[ "$mode" == "export" ]]; then
  opts="build/ExportOptions-AppStore-export.plist"
  sed 's#<string>upload</string>#<string>export</string>#' scripts/ExportOptions-AppStore.plist > "$opts"
fi

echo "==> exporting (${mode})"
rm -rf "$export_path"
xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$export_path" \
  -exportOptionsPlist "$opts" "${auth[@]}"
echo "==> app store ${mode} done"
