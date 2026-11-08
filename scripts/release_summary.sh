#!/bin/bash
# Drafts release notes with Claude Haiku (via the owner's `cldp` alias, print
# mode) from the commits and merged PRs since the previous release tag.
#
# Usage: scripts/release_summary.sh <version> <prev-tag> <out-dir>
# Writes <out-dir>/summary.txt (one sentence, top of the GitHub release) and
# <out-dir>/whats-new.txt (App Store "What's New", plain text).
#
# Fails open: if cldp is missing or errors, prompts on a TTY (blank = skip).
# Env: RELEASE_SUMMARY_SKIP=1 skips cldp; RELEASE_SUMMARY_ARGS overrides its
# args (default: -p --model claude-haiku-5-5).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$repo_root"

version="${1:?usage: release_summary.sh <version> <prev-tag> <out-dir>}"
prev_tag="${2:-}"
[[ -n "$prev_tag" ]] || prev_tag=$(git ls-remote --tags --refs upstream 'App-Store-*' | sed 's#.*refs/tags/##' | sort -V | tail -1)
out_dir="${3:?usage: release_summary.sh <version> <prev-tag> <out-dir>}"
mkdir -p "$out_dir"
rm -f "$out_dir/summary.txt" "$out_dir/whats-new.txt"

cldp_args="${RELEASE_SUMMARY_ARGS:--p --model claude-haiku-5-5}"
range="${prev_tag:+${prev_tag}..}${RELEASE_SUMMARY_END:-HEAD}"
commits=$(git log "$range" --no-merges --pretty=format:'- %s' | grep -iv -e 'poke' -e 'localiz' -e 'indentation' | head -120 || true)
since=""
[[ -n "$prev_tag" ]] && since=$(git log -1 --format=%cs "$prev_tag" 2>/dev/null || true)
prs=""
if [[ -n "$since" ]]; then
  prs=$(gh pr list --repo "$UPSTREAM_REPO" --state merged --search "merged:>=${since}" --limit 100 \
    --json title -q '.[] | "- " + .title' 2>/dev/null || true)
fi

prompt=$(cat <<PROMPT
Write release notes for version ${version} of Simple Comic, a macOS comic book reader. Base them on these merged pull request titles and recent commit subjects (ignore localization/internal housekeeping and tests; describe what users will notice; merge duplicates):

Pull requests:
${prs}

Commits (newest first):
${commits}

Output only a JSON object with two string keys:
- "summary": one plain-text sentence of at most 25 words for the top of the GitHub release page.
- "whats_new": plain text for the Mac App Store "What's New" field: a short intro line, then 3-8 lines starting with "• ". No markdown, under 1500 characters.
Output nothing outside the JSON object.
PROMPT
)

try_cldp() {
  local raw body rc
  raw=$(printf '%s' "$prompt" | perl -e 'alarm shift; exec @ARGV' 240 \
    bash -lic "printf '\n<<<BEGIN>>>\n'; cldp ${cldp_args}; rc=\$?; printf '\n<<<END rc=%s>>>\n' \"\$rc\"" 2>/dev/null || true)
  body=$(printf '%s\n' "$raw" | sed -n '/<<<BEGIN>>>/,/<<<END/p' | sed '1d;$d' \
    | grep -v -e '^Switched to profile ' -e '^All claude commands in this shell' || true)
  rc=$(printf '%s\n' "$raw" | sed -n 's/.*<<<END rc=\([0-9]*\)>>>.*/\1/p')
  [[ "$rc" == "0" ]] || return 1
  printf '%s' "$body" | python3 -I -c '
import json, re, sys
m = re.search(r"\{.*\}", sys.stdin.read(), re.S)
if not m: sys.exit(1)
d = json.loads(m.group(0))
s, w = d.get("summary", ""), d.get("whats_new", "")
if not (isinstance(s, str) and isinstance(w, str) and s.strip() and w.strip()): sys.exit(1)
out = sys.argv[1]
open(out + "/summary.txt", "w").write(" ".join(s.split()) + "\n")
open(out + "/whats-new.txt", "w").write(w.strip() + "\n")
' "$out_dir"
}

source_label=""
if [[ "${RELEASE_SUMMARY_SKIP:-0}" != "1" ]] && try_cldp; then
  source_label="cldp (Haiku)"
elif [[ -t 0 ]]; then
  echo "==> Haiku draft unavailable; enter a one-line summary (blank to skip):"
  read -r -p "> " line || line=""
  if [[ -n "$line" ]]; then
    printf '%s\n' "$line" > "$out_dir/summary.txt"
    printf '%s\n' "$line" > "$out_dir/whats-new.txt"
    source_label="manual"
  fi
fi

if [[ -s "$out_dir/summary.txt" ]]; then
  echo "==> release notes drafted by ${source_label}:"
  echo "--- summary ---"; cat "$out_dir/summary.txt"
  echo "--- App Store What's New ---"; cat "$out_dir/whats-new.txt"
else
  echo "==> no release notes drafted" >&2
fi
