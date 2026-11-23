#!/usr/bin/env bash
# Newest caddy-dns/cloudflare tag, and the vendor hash for it against this
# flake's caddy: a nixpkgs bump changes the hash too, so it's recomputed even
# when the tag hasn't moved. The hash is what nix reports for a build with
# the hash left empty.
set -euo pipefail

sources=${1:-sources.json}

latest=$(curl -fsSL https://api.github.com/repos/caddy-dns/cloudflare/tags | jq -er '.[0].name')
previous=$(cat "$sources")
jq --arg v "$latest" '.version = $v | .hash = ""' <<<"$previous" >"$sources"

if out=$(nix build --no-link .#caddy-cloudflare 2>&1); then
  echo "caddy-cloudflare built with an empty hash, which can't be right" >&2
  printf '%s\n' "$previous" >"$sources"
  exit 1
fi
hash=$(grep -oE 'got: +sha256-[A-Za-z0-9+/=]+' <<<"$out" | awk '{print $2}' | tail -1)
if [ -z "$hash" ]; then
  echo "$out" >&2
  printf '%s\n' "$previous" >"$sources"
  exit 1
fi

jq --arg v "$latest" --arg h "$hash" '.version = $v | .hash = $h' <<<"$previous" >"$sources"
echo "caddy-cloudflare: $(jq -r .version <<<"$previous") -> $latest, $hash"
