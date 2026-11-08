# Shared helpers for the release scripts. Source this; don't execute it.
#
# Env overrides (the repo is shared, so nothing owner-specific is hard-wired):
#   OP_ACCOUNT  1Password account holding the App Store Connect API key
#   OP_VAULT    vault name
#   OP_ITEM     item name (the .p8 is attached as a file; "issuer id" is a text field)
#   APPLE_TEAM  Apple Developer team ID
#   UPSTREAM_REPO  GitHub repo that hosts releases

OP_ACCOUNT="${OP_ACCOUNT:-nickfam.1password.com}"
OP_VAULT="${OP_VAULT:-Private}"
OP_ITEM="${OP_ITEM:-App Store Connect API Key File}"
UPSTREAM_REPO="${UPSTREAM_REPO:-MaddTheSane/Simple-Comic}"
BUNDLE_ID="com.ToWatchList.SimpleComic"
APP_NAME="Simple Comic"
SCHEME="Simple Comic"
PROJECT="SimpleComic.xcodeproj"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Prints "<marketing version> <build number>" of the Release configuration.
current_version() {
  xcodebuild -project "$repo_root/$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *MARKETING_VERSION =/ {v=$2} /^ *CURRENT_PROJECT_VERSION =/ {b=$2} END {print v, b}'
}

# Fetches the App Store Connect API key live from 1Password into a 0700 temp
# dir (deleted on exit) and exports ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID.
# Nothing is stored in the keychain or the repo.
asc_key_setup() {
  [[ -n "${ASC_KEY_PATH:-}" && -f "$ASC_KEY_PATH" ]] && return 0
  local key_filename
  key_filename=$(op item get "$OP_ITEM" --vault "$OP_VAULT" --account "$OP_ACCOUNT" --format json \
    | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["files"][0]["name"])')
  ASC_KEY_ID=$(echo "$key_filename" | sed -E 's/^AuthKey_([A-Za-z0-9]+)\.p8$/\1/')
  ASC_ISSUER_ID=$(op read "op://${OP_VAULT}/${OP_ITEM}/issuer id" --account "$OP_ACCOUNT")
  ASC_SECRET_DIR=$(mktemp -d)
  chmod 700 "$ASC_SECRET_DIR"
  trap 'rm -rf "$ASC_SECRET_DIR"' EXIT
  ASC_KEY_PATH="$ASC_SECRET_DIR/$key_filename"
  op read "op://${OP_VAULT}/${OP_ITEM}/${key_filename}" --account "$OP_ACCOUNT" --out-file "$ASC_KEY_PATH" >/dev/null
  chmod 600 "$ASC_KEY_PATH"
  export ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID
}

# Highest build number already uploaded to App Store Connect.
asc_latest_build() {
  asc_key_setup
  python3 -I "$repo_root/scripts/asc.py" latest-build
}
