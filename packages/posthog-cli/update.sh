#!/usr/bin/env bash
# Point sources.json at the newest posthog-cli. No-op when already current.
# The version is what npm's `latest` tag says (the same package that would
# download these binaries), and every platform's hash is prefetched from the
# exact file default.nix fetches.
set -euo pipefail

sources=${1:-sources.json}
base=https://github.com/PostHog/posthog/releases/download/posthog-cli

latest=$(curl -fsSL https://registry.npmjs.org/@posthog/cli/latest | jq -er .version)
current=$(jq -er .version "$sources")
if [ "$latest" = "$current" ]; then
  echo "posthog-cli is up to date at $current"
  exit 0
fi

echo "posthog-cli: $current -> $latest"
next=$(jq --arg v "$latest" '.version = $v' "$sources")
for system in $(jq -r '.files | keys[]' "$sources"); do
  file=$(jq -er --arg s "$system" '.files[$s]' "$sources")
  hash=$(nix store prefetch-file --json "$base/v$latest/$file" | jq -er .hash)
  echo "  $system: $hash"
  next=$(jq --arg s "$system" --arg h "$hash" '.hashes[$s] = $h' <<<"$next")
done
printf '%s\n' "$next" >"$sources"
