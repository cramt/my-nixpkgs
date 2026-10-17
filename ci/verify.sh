#!/usr/bin/env bash
# Builds each bump from bump.sh on this machine's system, one patch at a time
# against a clean tree, and records <name> ok|fail|skip in $2/<system>. skip is
# a package this system can't build (steamlink on x86), which shouldn't hold
# the bump back. Exits nonzero if anything failed, after trying the rest.
set -euo pipefail

bumps=$1
results=$2
mkdir -p "$results"
system=$(nix eval --raw --impure --expr builtins.currentSystem)
available=$(nix eval --json ".#packages.$system" --apply builtins.attrNames)

status=0
for patch in "$bumps"/*.patch; do
  [ -e "$patch" ] || continue
  name=$(basename "$patch" .patch)
  git apply "$patch"
  if ! jq -e --arg n "$name" 'index($n)' <<<"$available" >/dev/null; then
    result=skip
  elif nix build -L --no-link ".#packages.$system.$name"; then
    result=ok
  else
    result=fail
    status=1
  fi
  git checkout -q -- .
  echo "$name $result" | tee -a "$results/$system"
done
exit $status
