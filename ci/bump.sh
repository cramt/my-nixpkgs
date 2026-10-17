#!/usr/bin/env bash
# Runs every package's updater in isolation and leaves one patch per package
# that moved in $1 (<name>.patch, plus <name>.msg with the commit subject). One
# bump never rides along with another, so verify.sh can land the ones that build
# and hold back the ones that don't. Exits nonzero if any updater failed, after
# collecting the rest.
set -euo pipefail

out=$1
mkdir -p "$out"
system=$(nix eval --raw --impure --expr builtins.currentSystem)

version() { nix eval --raw ".#packages.$system.$1.version" 2>/dev/null || echo "?"; }

failed=()
for name in $(nix run .#update -- --list | jq -r '.[]'); do
  before=$(version "$name")
  if ! nix run .#update -- "$name"; then
    failed+=("$name")
  elif ! git diff --quiet; then
    git diff >"$out/$name.patch"
    echo "$name: $before -> $(version "$name")" >"$out/$name.msg"
    cat "$out/$name.msg"
  fi
  git checkout -q -- .
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "::error::updater failed: ${failed[*]}"
  exit 1
fi
