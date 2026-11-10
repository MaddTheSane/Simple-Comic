#!/bin/bash
# Archives and exports a Developer-ID-signed Release build of the app for the
# notarized standalone download. Produces build/export/Simple Comic.app.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$repo_root"

archive_path="build/SimpleComic.xcarchive"
export_path="build/export"

echo "==> archiving (Release, $DIRECT_SCHEME)"
rm -rf "$archive_path"
xcodebuild -project "$PROJECT" -scheme "$DIRECT_SCHEME" \
  -configuration Release clean archive -archivePath "$archive_path"

echo "==> exporting Developer-ID signed .app"
rm -rf "$export_path"
xcodebuild -exportArchive -archivePath "$archive_path" \
  -exportPath "$export_path" -exportOptionsPlist scripts/ExportOptions.plist

echo "==> exported: $export_path/$APP_NAME.app"
