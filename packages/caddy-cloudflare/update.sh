#!/usr/bin/env bash
# Newest caddy-dns/cloudflare tag against this flake's caddy: regenerate src/
# (main.go, go.mod, go.sum) with xcaddy, then the vendor hash, which is what
# nix reports for a build with it left empty.
set -euo pipefail

sources=${1:-sources.json}
dir=$(dirname "$sources")

caddy_version=$(nix eval --raw .#caddy-cloudflare.version)
plugin=$(curl -fsSL https://api.github.com/repos/caddy-dns/cloudflare/tags | jq -er '.[0].name')
previous=$(cat "$sources")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
nix shell --inputs-from . nixpkgs#go nixpkgs#xcaddy -c env \
  GOTOOLCHAIN=local GOPATH="$work/gopath" GOCACHE="$work/gocache" GOFLAGS=-modcacherw \
  XCADDY_SKIP_BUILD=1 TMPDIR="$work" \
  xcaddy build "v$caddy_version" --with "github.com/caddy-dns/cloudflare@$plugin"
rm -rf "$dir/src"
mkdir "$dir/src"
cp "$work"/buildenv*/{main.go,go.mod,go.sum} "$dir/src/"
# A flake only sees tracked files.
git add "$dir/src"

jq --arg p "$plugin" '.plugin = $p | .vendorHash = ""' <<<"$previous" >"$sources"
if out=$(nix build --no-link .#caddy-cloudflare 2>&1); then
  echo "caddy-cloudflare built with an empty vendor hash, which can't be right" >&2
  exit 1
fi
hash=$(grep -oE 'got: +sha256-[A-Za-z0-9+/=]+' <<<"$out" | awk '{print $2}' | tail -1)
if [ -z "$hash" ]; then
  echo "$out" >&2
  exit 1
fi
jq --arg p "$plugin" --arg h "$hash" '.plugin = $p | .vendorHash = $h' <<<"$previous" >"$sources"
echo "caddy-cloudflare: caddy $caddy_version, cloudflare $plugin, $hash"
