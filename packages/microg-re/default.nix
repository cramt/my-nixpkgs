{
  lib,
  stdenv,
  fetchurl,
}:
# Morphe's microG build: Google sign-in for the patched YouTube and YouTube Music
# without Play Services (revanced-magisk-module's non-root APKs). It installs as
# app.revanced.android.gms, the name those apps look for. The package is the APK
# itself, the variant without a launcher icon. sources.json is rewritten by
# `nix run .#update -- microg-re`.
let
  sources = lib.importJSON ./sources.json;
  inherit (sources) version;

  # As revanced-magisk-module: phones are ARM, and x86_64 (CI) fetches the arm64
  # APK, whose store path is the same one an arm64 phone asks for.
  abi =
    if stdenv.hostPlatform.isAarch32
    then "armeabi-v7a"
    else "arm64-v8a";
in
  fetchurl {
    name = "microg-re-${version}-${abi}.apk";
    url = "https://github.com/MorpheApp/MicroG-RE/releases/download/${version}/microg-${version}-noicon-${abi}.apk";
    hash = sources.hashes.${abi};

    passthru = {
      inherit version;
      packageName = "app.revanced.android.gms";
    };

    meta = {
      description = "microG GmsCore for Morphe-patched Google apps";
      homepage = "https://github.com/MorpheApp/MicroG-RE";
      license = lib.licenses.asl20;
      sourceProvenance = [lib.sourceTypes.binaryBytecode];
      platforms = lib.platforms.linux;
    };
  }
