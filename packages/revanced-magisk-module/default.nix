{
  lib,
  stdenv,
  fetchurl,
  runCommand,
}:
# Everything j-hc/revanced-magisk-module's CI patches (YouTube, Music, Reddit with
# Morphe's patches, Twitter with Piko's, Google Photos with De-Vanced's), as the
# APKs and Magisk modules it publishes. Nothing is patched here. sources.json is
# rewritten by `nix run .#update -- revanced-magisk-module`.
#
# Use the files through passthru.apps, e.g. revanced-magisk-module.apps.youtube.apk:
# each is its own fixed-output fetch, so a phone pulls only the apps it installs.
# The package itself just links them all, so CI caches every one.
let
  sources = lib.importJSON ./sources.json;
  repo = "https://github.com/j-hc/revanced-magisk-module";

  # Phones are ARM. On anything else (CI's x86_64 leg) take the arm64 builds: a
  # fixed-output path doesn't depend on the system that fetched it, so that leg
  # caches exactly the paths an arm64 phone asks for.
  abi =
    if stdenv.hostPlatform.isAarch32
    then "arm-v7a"
    else "arm64-v8a";

  fetch = tag: file:
    fetchurl {
      url = "${repo}/releases/download/${tag}/${file.name}";
      inherit (file) name hash;
    };

  # A universal file ("all") if there is one, else this ABI's; null when the app
  # has no file of that kind (Reddit and Twitter ship no module).
  pick = tag: files: let
    file = files.all or files.${abi} or null;
  in
    if file == null
    then null
    else fetch tag file;

  apps = lib.mapAttrs (_: app: {
    inherit (app) brand version;
    apk = pick app.tag app.apk;
    module = pick app.tag app.module;
  })
  sources.apps;

  links = lib.concatLists (lib.mapAttrsToList (name: app:
    lib.optional (app.apk != null) "ln -s ${app.apk} $out/${name}.apk"
    ++ lib.optional (app.module != null) "ln -s ${app.module} $out/${name}-module.zip")
  apps);
in
  runCommand "revanced-magisk-module-${sources.version}" {
    inherit (sources) version;
    passthru = {inherit apps;};
    meta = {
      description = "Patched YouTube, YouTube Music, Reddit, Twitter and Google Photos from j-hc's CI";
      homepage = repo;
      # The patches are GPL, the apps they patch aren't.
      license = lib.licenses.unfree;
      sourceProvenance = [lib.sourceTypes.binaryBytecode];
      platforms = lib.platforms.linux;
    };
  } ''
    mkdir $out
    ${lib.concatStringsSep "\n" links}
  ''
