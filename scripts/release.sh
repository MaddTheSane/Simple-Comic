#!/bin/bash
# One-command release: App Store + notarized GitHub release.
#
#   scripts/release.sh [--dry-run] [--yes] [--release manual|auto]
#   env: VERSION=1.11.0 BUILD=362  (BUILD defaults to latest uploaded build + 1)
#
# Stages (each is also a Makefile target and safe to retry):
#   1 preflight   tools, auth, ASC build number, clean tree
#   2 notes       Haiku drafts (REUSE_NOTES=1 keeps already-approved files) the summary + App Store What's New  -> APPROVAL STOP
#   3 bump        version-bump PR into upstream arc, merged; everything below builds
#                 from the merged commit, which is also what gets tagged
#   4 build       tests, Developer-ID export, notarize, verify
#   5 app store   upload, wait for processing, attach build, submit for review
#   6 github      tag, push tag, release on $UPSTREAM_REPO marked Latest
#   7 install     notarized app to /Applications
#
# --dry-run runs 1, 2 and the local half of 4 (no bump PR, upload, tag or publish).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$repo_root"

dry_run=0; assume_yes=0; release_mode=manual
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --yes) assume_yes=1 ;;
    --release) release_mode="${2:?}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

version="${VERSION:?set VERSION, e.g. VERSION=1.11.0}"
tag="App-Store-${version}"
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ---- 1 preflight --------------------------------------------------------
step "preflight"
for tool in xcodebuild gh op git python3 xcrun sign_update xmllint; do
  command -v "$tool" >/dev/null || { echo "error: missing $tool" >&2; exit 1; }
done
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "error: no Developer ID Application identity in the keychain" >&2; exit 1; }
# The Sparkle signing key must exist in the login keychain (sign_update reads it from there).
security find-generic-password -s "https://sparkle-project.org" -a "$SPARKLE_ACCOUNT" >/dev/null 2>&1 \
  || { echo "error: no Sparkle key for account '$SPARKLE_ACCOUNT' in the keychain (generate_keys --account $SPARKLE_ACCOUNT)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh not authenticated" >&2; exit 1; }
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "error: working tree not clean" >&2; exit 1; }
git fetch upstream --tags --quiet
latest_build=$(asc_latest_build)
build="${BUILD:-$((latest_build + 1))}"
(( build > latest_build )) || { echo "error: BUILD $build is not above uploaded build $latest_build" >&2; exit 1; }
prev_tag=$(git ls-remote --tags --refs upstream 'App-Store-*' | sed 's#.*refs/tags/##' | sort -V | tail -1)
echo "version $version, build $build (latest uploaded: $latest_build), previous release: $prev_tag"
if git ls-remote --exit-code --tags upstream "refs/tags/$tag" >/dev/null 2>&1; then
  echo "error: $tag already exists on upstream" >&2; exit 1
fi

# ---- 2 notes + approval -------------------------------------------------
step "release notes"
notes_dir="build/release-$version"
git rev-parse --verify -q upstream/arc >/dev/null
if [[ "${REUSE_NOTES:-0}" == "1" && -s "$notes_dir/summary.txt" && -s "$notes_dir/whats-new.txt" ]]; then
  echo "reusing the already-approved notes in $notes_dir"
else
  RELEASE_SUMMARY_END=upstream/arc scripts/release_summary.sh "$version" "$prev_tag" "$notes_dir"
fi
[[ -s "$notes_dir/summary.txt" ]] || { echo "error: no release notes; edit $notes_dir/*.txt and re-run" >&2; exit 1; }
if (( ! assume_yes )); then
  echo
  echo "Edit $notes_dir/summary.txt and whats-new.txt now if needed."
  echo "Proceeding will: $( ((dry_run)) && echo 'dry run only (no push/upload/publish)' \
    || echo "open+merge a bump PR on $UPSTREAM_REPO, upload build $build to App Store Connect, submit for review (release=$release_mode), tag $tag and publish the GitHub release (Latest)")."
  read -r -p "Approve? [y/N] " ok
  [[ "$ok" == "y" || "$ok" == "Y" ]] || { echo "aborted"; exit 1; }
fi

# ---- 3 bump PR ------------------------------------------------------------
if (( dry_run )); then
  step "dry run: skipping bump PR; building from HEAD ($(git rev-parse --short HEAD))"
else
  step "version bump PR"
  branch="App-Store-${version}-branch"
  git switch -C "$branch" upstream/arc
  git submodule update --init --recursive
  read -r cur_ver cur_build < <(current_version)
  sed -i '' -E "s/(MARKETING_VERSION = )${cur_ver//./\\.};/\1${version};/; s/(CURRENT_PROJECT_VERSION = )${cur_build};/\1${build};/" "$PROJECT/project.pbxproj"
  git commit -am "Update marketing version to ${version}." -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
  git push -u upstream "$branch"
  pr_url=$(gh pr create --repo "$UPSTREAM_REPO" --base arc --head "$branch" \
    --title "Update marketing version to ${version}." \
    --body "Version and build bump for the App Store and notarized release (${version}, build ${build}).")
  gh pr merge "$pr_url" --repo "$UPSTREAM_REPO" --squash
  git fetch upstream --quiet
  git checkout --detach upstream/arc
  git submodule update --init --recursive
fi
sha=$(git rev-parse HEAD)
echo "building from $sha"

# ---- 4 build, verify ------------------------------------------------------
step "tests"
make test
step "Developer-ID build + notarize"
scripts/build_release.sh
if (( dry_run )); then
  # Nothing was bumped, so the artifact carries the project's current version.
  read -r version build < <(current_version)
fi
scripts/notarize.sh "$version"
scripts/verify_release.sh "dist/Simple.Comic.${version}.zip" "$version" "$build"
step "Sparkle appcast"
scripts/sparkle_appcast.sh "$version" "$build" "dist/Simple.Comic.${version}.zip" "$notes_dir/summary.txt"

if (( dry_run )); then
  step "dry run complete (nothing pushed, uploaded, tagged or published)"
  exit 0
fi

# ---- 5 app store ----------------------------------------------------------
step "App Store upload"
scripts/upload_app_store.sh upload
asc_key_setup
python3 -I scripts/asc.py wait-build "$build"
python3 -I scripts/asc.py submit --version "$version" --build "$build" \
  --whats-new-file "$notes_dir/whats-new.txt" --release "$release_mode"

# ---- 6 github -------------------------------------------------------------
step "GitHub release"
git tag "$tag" "$sha"
git push upstream "$tag"
{ echo "Submitted to the [Mac App Store](https://apps.apple.com/us/app/simple-comic/id1497435571?mt=12)."; echo
  cat "$notes_dir/summary.txt"; } > "$notes_dir/body-head.md"
gh release create "$tag" "dist/Simple.Comic.${version}.zip" dist/appcast.xml --repo "$UPSTREAM_REPO" \
  --target "$sha" --title "$tag" --latest \
  --generate-notes --notes-start-tag "$prev_tag" --notes-file "$notes_dir/body-head.md"
gh release view "$tag" --repo "$UPSTREAM_REPO" --json url,isLatest,assets -q '.url'

# ---- 7 install ------------------------------------------------------------
step "install locally"
scripts/install_local.sh
step "done: $tag"
