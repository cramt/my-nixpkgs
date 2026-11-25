#!/usr/bin/env bash
# Point sources.json at the newest stable APK on pkgs.tailscale.com. No-op when
# already current. nix-update can't: the version comes from that site's JSON
# index, not a git tag of the source repo.
set -euo pipefail

sources=${1:-sources.json}

latest=$(curl -fsSL 'https://pkgs.tailscale.com/stable/?mode=json' | jq -er .APKsVersion)
current=$(jq -er .version "$sources")
if [ "$latest" = "$current" ]; then
  echo "tailscale-android is up to date at $current"
  exit 0
fi

echo "tailscale-android: $current -> $latest"
hash=$(nix store prefetch-file --json --name "tailscale-android-$latest.apk" \
  "https://pkgs.tailscale.com/stable/tailscale-android-universal-$latest.apk" | jq -er .hash)
jq -S -n --arg v "$latest" --arg h "$hash" '{version: $v, hash: $h}' >"$sources"
