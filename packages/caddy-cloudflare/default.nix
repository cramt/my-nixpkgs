# Caddy with the Cloudflare DNS provider (github.com/caddy-dns/cloudflare), for
# ACME DNS-01: certificates for names that resolve to tailnet addresses, which
# no HTTP or TLS-ALPN challenge can reach.
#
# withPlugins vendors the plugin's Go modules into a fixed-output derivation,
# so its hash depends on nixpkgs' caddy as well as the plugin version.
# update.sh recomputes it on every run, not only on a new tag.
{
  lib,
  caddy,
}: let
  sources = lib.importJSON ./sources.json;
in
  caddy.withPlugins {
    plugins = ["github.com/caddy-dns/cloudflare@${sources.version}"];
    hash =
      if sources.hash == ""
      then lib.fakeHash
      else sources.hash;
  }
