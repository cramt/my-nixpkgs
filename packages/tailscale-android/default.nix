{
  lib,
  fetchurl,
}:
# Tailscale's Android client, the APK Tailscale itself publishes (the Play Store
# build's signer, so either can update the other). One universal APK for every
# ABI. sources.json is rewritten by `nix run .#update -- tailscale-android`.
let
  sources = lib.importJSON ./sources.json;
  inherit (sources) version;
in
  fetchurl {
    name = "tailscale-android-${version}.apk";
    url = "https://pkgs.tailscale.com/stable/tailscale-android-universal-${version}.apk";
    inherit (sources) hash;

    passthru = {
      inherit version;
      packageName = "com.tailscale.ipn";
    };

    meta = {
      description = "Tailscale VPN client for Android";
      homepage = "https://github.com/tailscale/tailscale-android";
      license = lib.licenses.bsd3;
      sourceProvenance = [lib.sourceTypes.binaryBytecode];
      platforms = lib.platforms.linux;
    };
  }
