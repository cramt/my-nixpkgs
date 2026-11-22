{
  stdenvNoCC,
  lib,
  fetchurl,
  makeWrapper,
  nix-update-script,
  nodejs,
}:
# The pi coding agent (pi.dev). Not in nixpkgs. Since 1.x the npm tarball
# ships dist/bundle fully bundled (no node_modules needed), so it only needs
# node. T3 Code's Pi driver wants 0.84.3 or newer.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pi-coding-agent";
  version = "1.6.0";

  src = fetchurl {
    url = "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-${finalAttrs.version}.tgz";
    hash = "sha256-hdXeQE4BnoUMkO6axtxsFiQNoSL9zgMUiVYIFkAwM2s=";
  };

  nativeBuildInputs = [makeWrapper];

  dontConfigure = true;
  dontBuild = true;

  # docs/ and examples/ stay: pi points the model at its own docs when asked
  # how to write extensions.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/node_modules/pi-coding-agent
    cp -r . $out/lib/node_modules/pi-coding-agent

    makeWrapper ${lib.getExe nodejs} $out/bin/pi \
      --add-flags $out/lib/node_modules/pi-coding-agent/dist/bundle/cli.js

    runHook postInstall
  '';

  passthru.updateScript = nix-update-script {};

  meta = {
    description = "pi, a minimal coding agent harness";
    homepage = "https://pi.dev";
    license = lib.licenses.mit;
    mainProgram = "pi";
  };
})
