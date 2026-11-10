#!/bin/bash
# Signs the notarized zip with the Sparkle EdDSA key from the login keychain and
# writes dist/appcast.xml (a single <item> for this release). The appcast is
# uploaded as an asset of the GitHub release; the app's SUFeedURL points at
# .../releases/latest/download/appcast.xml, so "latest" always serves the newest.
#
# One-time setup: `brew install sparkle` (provides sign_update), and create the key with
#   generate_keys --account SimpleComic     # prints SUPublicEDKey; Sparkle's tool
# (generate_keys ships in the Sparkle release tarball; back it up with `generate_keys --account SimpleComic -x file`).
#
# Usage: scripts/sparkle_appcast.sh <version> <build> <zip> [summary-file]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
version="${1:?usage: sparkle_appcast.sh <version> <build> <zip> [summary-file]}"
build="${2:?}"; zip="${3:?}"; summary_file="${4:-}"
out="$repo_root/dist/appcast.xml"

command -v sign_update >/dev/null || { echo "error: sign_update not found (brew install sparkle)" >&2; exit 1; }

sig_output=$(sign_update --account "$SPARKLE_ACCOUNT" "$zip")
signature=$(grep -oE 'sparkle:edSignature="[^"]+"' <<<"$sig_output" | sed -E 's/.*="([^"]+)"/\1/')
length=$(/usr/bin/stat -f%z "$zip")
[[ -n "$signature" ]] || { echo "error: sign_update produced no signature: $sig_output" >&2; exit 1; }

tag="App-Store-${version}"
url="https://github.com/${UPSTREAM_REPO}/releases/download/${tag}/$(basename "$zip")"
notes_url="https://github.com/${UPSTREAM_REPO}/releases/tag/${tag}"
summary=""
[[ -n "$summary_file" && -f "$summary_file" ]] && summary=$(python3 -I -c 'import html,sys; print(html.escape(open(sys.argv[1]).read().strip()))' "$summary_file")
pub_date=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

mkdir -p "$(dirname "$out")"
cat > "$out" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Simple Comic</title>
    <link>https://github.com/${UPSTREAM_REPO}</link>
    <description>Simple Comic updates</description>
    <language>en</language>
    <item>
      <title>${version}</title>
      <pubDate>${pub_date}</pubDate>
      <sparkle:version>${build}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.6</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>${notes_url}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[<p>${summary}</p><p><a href="${notes_url}">Full release notes</a></p>]]></description>
      <enclosure url="${url}" sparkle:edSignature="${signature}" length="${length}" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$out"
echo "==> wrote $out (build $build, ${length} bytes)"
