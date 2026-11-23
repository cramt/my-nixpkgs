# Caddy with the Cloudflare DNS provider (github.com/caddy-dns/cloudflare), for
# ACME DNS-01: certificates for names that resolve to tailnet addresses, which
# no HTTP or TLS-ALPN challenge can reach.
#
# Not caddy.withPlugins: that generates go.mod inside its fixed-output source,
# with the building Go's version in the `go` line, so a consumer whose nixpkgs
# has another Go (any flake that follows its own nixpkgs) gets another hash.
# update.sh runs xcaddy once and commits the module files in src/; the vendor
# hash then only depends on go.sum.
{
  lib,
  caddy,
}: let
  sources = lib.importJSON ./sources.json;
in
  caddy.overrideAttrs (_: {
    pname = "caddy-cloudflare";
    src = ./src;
    vendorHash =
      if sources.vendorHash == ""
      then lib.fakeHash
      else sources.vendorHash;
    subPackages = ["."];
    # Same as withPlugins: a build-tag fallback that doesn't compile outside
    # caddy's own module.
    postConfigure = ''
      chmod u+w vendor/github.com/caddyserver/caddy/v2/cmd
      rm vendor/github.com/caddyserver/caddy/v2/cmd/x509rootsfallback.go
    '';
    passthru = (caddy.passthru or {}) // {inherit (sources) plugin;};
  })
