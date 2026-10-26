#!/usr/bin/env bash
# Point sources.json at the newest stable desktop build. No-op when already
# current. nix-update can't do this: it reads the releases atom feed, which only
# holds the newest 10 entries, and Fluxer tags a dozen backend services a day in
# the same repo, so the desktop tag is almost never in that window. Page through
# the API instead; ~85 other releases between two desktop builds has happened.
set -euo pipefail

sources=${1:-sources.json}
prefix=fluxer-desktop-stable@

auth=()
[ -z "${GITHUB_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $GITHUB_TOKEN")

latest=
for page in 1 2 3 4 5; do
  latest=$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/fluxerapp/fluxer/releases?per_page=100&page=$page" |
    jq -r --arg p "$prefix" '[.[] | select(.prerelease | not) | .tag_name | select(startswith($p)) | ltrimstr($p)][0] // empty')
  [ -z "$latest" ] || break
done
[ -n "$latest" ] || { echo "fluxer: no $prefix release in the newest 500" >&2; exit 1; }

current=$(jq -er .version "$sources")
if [ "$latest" = "$current" ]; then
  echo "fluxer is up to date at $current"
  exit 0
fi

echo "fluxer: $current -> $latest"
url="https://github.com/fluxerapp/fluxer/releases/download/${prefix//@/%40}$latest/Fluxer-$latest-linux-x86_64.AppImage"
hash=$(nix store prefetch-file --json --name "Fluxer-$latest-linux-x86_64.AppImage" "$url" | jq -er .hash)
jq --arg v "$latest" --arg h "$hash" '.version = $v | .hash = $h' "$sources" >"$sources.tmp"
mv "$sources.tmp" "$sources"
