#!/usr/bin/env bash
# Point sources.json at MicroG-RE's newest release. No-op when already current.
# nix-update can't: it would bump the version but has no idea which of the
# release's APKs the hashes belong to.
set -euo pipefail

sources=${1:-sources.json}
repo=MorpheApp/MicroG-RE

auth=()
[ -z "${GITHUB_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $GITHUB_TOKEN")

latest=$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/$repo/releases/latest" | jq -er .tag_name)
current=$(jq -er .version "$sources")
if [ "$latest" = "$current" ]; then
  echo "microg-re is up to date at $current"
  exit 0
fi

echo "microg-re: $current -> $latest"
next=$(jq --arg v "$latest" '.version = $v | .hashes = {}' "$sources")
for abi in arm64-v8a armeabi-v7a; do
  name="microg-$latest-noicon-$abi.apk"
  hash=$(nix store prefetch-file --json --name "$name" \
    "https://github.com/$repo/releases/download/$latest/$name" | jq -er .hash)
  next=$(jq --arg a "$abi" --arg h "$hash" '.hashes[$a] = $h' <<<"$next")
done
jq -S . <<<"$next" >"$sources"
