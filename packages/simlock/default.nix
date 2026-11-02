# Simlock (https://github.com/callstackincubator/simlock): a control plane that
# leases iOS simulators, Android emulators and phones to coding agents, so
# parallel agents stop fighting over one device. One `simlock` CLI is both the
# worker daemon (on the machine with the devices) and the gateway (one URL in
# front of several workers); t3code's Labs "Simlock device hosts" talks to the
# gateway.
#
# Pure JS on npm with no install scripts, so it builds offline from the
# committed lockfile; update.sh regenerates it.
{
  lib,
  stdenvNoCC,
  importNpmLock,
  nodejs_24,
  makeBinaryWrapper,
}: let
  lock = lib.importJSON ./package-lock.json;
  version = lock.packages."node_modules/simlock".version;
  nodeModules = importNpmLock.buildNodeModules {
    npmRoot = ./.;
    nodejs = nodejs_24;
  };
in
  stdenvNoCC.mkDerivation {
    pname = "simlock";
    inherit version;
    dontUnpack = true;
    nativeBuildInputs = [makeBinaryWrapper];
    installPhase = ''
      mkdir -p $out/lib $out/bin
      cp -r ${nodeModules}/node_modules $out/lib/node_modules
      makeWrapper ${lib.getExe nodejs_24} $out/bin/simlock \
        --add-flags $out/lib/node_modules/simlock/dist/cli/main.js
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      HOME=$TMPDIR $out/bin/simlock --help >/dev/null
    '';
    meta = {
      description = "Control plane that leases simulators, emulators and phones to coding agents";
      homepage = "https://github.com/callstackincubator/simlock";
      license = lib.licenses.mit;
      mainProgram = "simlock";
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
    };
  }
