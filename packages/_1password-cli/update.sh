#!/usr/bin/env bash
# Point sources.json at the newest stable 1Password CLI. No-op when already
# current. The version comes from the same update-check endpoint `op update`
# asks (claiming to be 2.0.0 so it always offers the latest), and every
# platform's hash is prefetched from the exact file default.nix fetches.
set -euo pipefail

sources=${1:-sources.json}
base=https://cache.agilebits.com/dist/1P/op2/pkg

latest=$(curl -fsSL https://app-updates.agilebits.com/check/1/0/CLI2/en/2.0.0/N | jq -er .version)
current=$(jq -er .version "$sources")
if [ "$latest" = "$current" ]; then
  echo "1password-cli is up to date at $current"
  exit 0
fi

echo "1password-cli: $current -> $latest"
next=$(jq --arg v "$latest" '.version = $v' "$sources")
for system in $(jq -r '.files | keys[]' "$sources"); do
  file=$(jq -er --arg s "$system" '.files[$s]' "$sources")
  file=${file//@version@/$latest}
  hash=$(nix store prefetch-file --json "$base/v$latest/$file" | jq -er .hash)
  echo "  $system: $hash"
  next=$(jq --arg s "$system" --arg h "$hash" '.hashes[$s] = $h' <<<"$next")
done
printf '%s\n' "$next" >"$sources"
