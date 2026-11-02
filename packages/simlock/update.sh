#!/usr/bin/env bash
# Pin package.json to simlock's newest npm release and regenerate the lockfile.
# No-op when already current.
set -euo pipefail

dir=$(dirname "${1:-packages/simlock/sources.json}")
current=$(jq -er '.dependencies.simlock' "$dir/package.json")
latest=$(npm view simlock version)
if [ "$latest" = "$current" ]; then
  echo "simlock is up to date at $current"
  exit 0
fi
echo "simlock: $current -> $latest"
jq --arg v "$latest" '.dependencies.simlock = $v' "$dir/package.json" >"$dir/package.json.new"
mv "$dir/package.json.new" "$dir/package.json"
rm -f "$dir/package-lock.json"
(cd "$dir" && npm install --package-lock-only --ignore-scripts --no-fund --no-audit >/dev/null)
