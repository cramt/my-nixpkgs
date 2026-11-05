# Reconciles a running T3 Code server's projects and scheduled tasks with a
# declared spec. nixosModules.t3code writes the spec and runs this after the
# server starts; see src/main.ts for what it owns and what it leaves alone.
#
# No updater: the source lives here, and its only dependencies are the
# compiler and node's types, which don't reach the output.
{
  lib,
  buildNpmPackage,
  nodejs_24,
  makeBinaryWrapper,
}:
buildNpmPackage {
  pname = "t3code-declare";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [./package.json ./package-lock.json ./tsconfig.json ./src];
  };
  nodejs = nodejs_24;
  npmDepsHash = "sha256-PMUxTQaniySo4ygTe1kI9OcJlRsq0Nt6rpD+x61byhQ=";
  nativeBuildInputs = [makeBinaryWrapper];

  installPhase = ''
    runHook preInstall
    install -Dm444 dist/main.js $out/lib/t3code-declare/main.js
    # Native WebSocket and fetch: node 22+ ships both, so the output has no
    # node_modules at all.
    makeWrapper ${lib.getExe nodejs_24} $out/bin/t3code-declare \
      --add-flags $out/lib/t3code-declare/main.js
    runHook postInstall
  '';

  meta = {
    description = "Declarative projects and scheduled tasks for a T3 Code server";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "t3code-declare";
  };
}
