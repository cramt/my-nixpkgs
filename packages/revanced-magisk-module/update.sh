#!/usr/bin/env bash
# Point sources.json at the newest build of every app j-hc's CI patches. No-op
# when nothing moved.
#
# A release only carries the apps rebuilt in that run (Twitter on its own one
# day, YouTube/Music/Reddit another), so the latest release is never the whole
# set: each app comes from the newest release that has it, along with all of its
# files there (APK and Magisk module, per ABI). An app j-hc drops falls out once
# it's older than the releases looked at.
set -euo pipefail

sources=${1:-sources.json}
repo=j-hc/revanced-magisk-module

auth=()
[ -z "${GITHUB_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $GITHUB_TOKEN")

# <app>-<brand>[-module]-v<version>-<abi>.(apk|zip), e.g.
# youtube-morphe-module-v21.30.216-all.zip, twitter-piko-v12.40.1-prod.01-all.apk
latest=$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/$repo/releases?per_page=50" | jq '
  [ .[] | select(.draft | not) | .tag_name as $tag | .assets[].name
    | capture("^(?<app>[a-z0-9]+)-(?<brand>[a-z0-9]+)(?<module>-module)?-v(?<version>.+)-(?<abi>all|arm64-v8a|arm-v7a|x86_64|x86)\\.(apk|zip)$")
    + { tag: $tag, name: . }
  ] as $files
  # Releases come newest first, so an app'"'"'s first file names its newest release.
  | ($files | map(.app) | unique) as $apps
  | {
      apps: ($apps | map(. as $app
        | ($files | map(select(.app == $app)) | .[0].tag) as $tag
        | ($files | map(select(.app == $app and .tag == $tag))) as $own
        | { key: $app, value: {
            brand: $own[0].brand,
            version: $own[0].version,
            tag: $tag,
            apk: ($own | map(select(.module == null) | { key: .abi, value: { name } }) | from_entries),
            module: ($own | map(select(.module != null) | { key: .abi, value: { name } }) | from_entries)
          } }
      ) | from_entries)
    }
  | .version = ([.apps[].tag] | max)
')

current=$(cat "$sources" 2>/dev/null || echo '{}')

# Hashes carry over for files already pinned (same release, same name); only new
# ones are downloaded.
next=$latest
while IFS=$'\t' read -r app kind abi tag name; do
  hash=$(jq -r --arg a "$app" --arg k "$kind" --arg b "$abi" --arg t "$tag" --arg n "$name" '
    .apps[$a] | select(.tag == $t) | .[$k][$b] | select(.name == $n) | .hash // empty' <<<"$current")
  if [ -z "$hash" ]; then
    echo "revanced-magisk-module: fetching $name ($tag)" >&2
    hash=$(nix store prefetch-file --json --name "$name" \
      "https://github.com/$repo/releases/download/$tag/$name" | jq -er .hash)
  fi
  next=$(jq --arg a "$app" --arg k "$kind" --arg b "$abi" --arg h "$hash" '.apps[$a][$k][$b].hash = $h' <<<"$next")
done < <(jq -r '.apps | to_entries[] | .key as $app | .value as $v
  | ("apk", "module") as $kind | $v[$kind] | to_entries[]
  | [$app, $kind, .key, $v.tag, .value.name] | @tsv' <<<"$latest")

if [ "$(jq -S . <<<"$next")" = "$(jq -S . <<<"$current")" ]; then
  echo "revanced-magisk-module is up to date at $(jq -r .version <<<"$current")"
  exit 0
fi

echo "revanced-magisk-module: $(jq -r '.version // "none"' <<<"$current") -> $(jq -r .version <<<"$next")"
jq -S . <<<"$next" >"$sources"
