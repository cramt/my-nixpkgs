#!/usr/bin/env bash
# Point sources.json at the newest t3code nightly. No-op when already current.
#
# The src hash comes from prefetching the tag. The other three are fixed-output
# derivations whose hash only falls out of fetching them, so each is reset to
# the fake hash and built: the mismatch error reports the real one. Resetting
# (rather than trying the old hash) matters because a FOD whose hash didn't
# change is never refetched, so a stale hash would silently keep old content.
set -euo pipefail

repo=pingdotgg/t3code
sources=${1:-sources.json}
fake=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

current=$(jq -er .version "$sources")
# Captured whole, not piped to head: head closing early would SIGPIPE
# ls-remote, which pipefail turns into a silent exit.
tags=$(git ls-remote --tags --refs --sort=-v:refname "https://github.com/$repo" 'v*-nightly.*')
latest=$(sed -n '1s|.*refs/tags/v||p' <<<"$tags")

if [ -z "$latest" ]; then
  echo "no nightly tags found on $repo" >&2
  exit 1
fi
if [ "$latest" = "$current" ]; then
  echo "t3code is up to date at $current"
  exit 0
fi
echo "t3code: $current -> $latest"

set_field() {
  local next
  next=$(jq --arg v "$2" "$1 = \$v" "$sources")
  printf '%s\n' "$next" >"$sources"
}

# Build a FOD with its hash set to $fake and write the hash nix reports.
resolve() {
  local field=$1 attr=$2 got
  set_field "$field" "$fake"
  got=$(nix build --no-link ".#$attr" 2>&1 | grep -oP 'got:\s+\Ksha256-\S+' || true)
  if [ -z "$got" ]; then
    echo "could not resolve $field from .#$attr" >&2
    exit 1
  fi
  echo "  $field: $got"
  set_field "$field" "$got"
}

set_field .version "$latest"
src=$(nix flake prefetch --json "github:$repo/v$latest" | jq -er .hash)
echo "  .hash: $src"
set_field .hash "$src"

spdx=$(curl -fsSL "https://raw.githubusercontent.com/$repo/v$latest/scripts/lib/third-party-licenses.ts" |
  sed -n 's/^const SPDX_LICENSE_LIST_REVISION = "\(.*\)";/\1/p')
if [ "$spdx" != "$(jq -er .spdx.rev "$sources")" ]; then
  set_field .spdx.rev "$spdx"
  resolve .spdx.hash t3code.spdxLicenses
fi

# The preview browser pin is upstream's own: version plus each zip's sha256,
# which fetchurl takes verbatim, so there is nothing to resolve.
browser=$(curl -fsSL "https://raw.githubusercontent.com/$repo/v$latest/apps/server/src/preview/PreviewBrowser.ts")
browser_pin() {
  awk -v key="$1" '
    $0 ~ "^  \"?" key "\"?: \\{" { found = 1 }
    found && /sha256:/ { gsub(/[^0-9a-f]/, "", $2); print $2; exit }
  ' <<<"$browser"
}
set_field .headlessShell.version "$(sed -n 's/^const VERSION = "\(.*\)";/\1/p' <<<"$browser")"
for platform in linux64 linux-arm64; do
  sha=$(browser_pin "$platform")
  if [ -z "$sha" ]; then
    echo "could not read the $platform headless shell sha256" >&2
    exit 1
  fi
  set_field ".headlessShell[\"$platform\"]" "$sha"
done
echo "  .headlessShell: $(jq -c .headlessShell "$sources")"

resolve .pnpmDepsHash t3code.pnpmDeps
resolve .cargoHash t3code.resourceMonitor.cargoDeps
