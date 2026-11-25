{
  buildNpmPackage,
  lib,
  fetchurl,
  nix-update-script,
  nodejs,
}:
# The pi coding agent (pi.dev). Not in nixpkgs. dist/bundle is prebuilt, but
# it still requires jiti (to load .ts extensions), typebox and a few others
# at runtime, so the real dependency tree goes in. The npm tarball has no
# lockfile; package-lock.json here is generated, and nix-update regenerates it
# on every bump. T3 Code's Pi driver wants 0.84.3 or newer.
buildNpmPackage (finalAttrs: {
  pname = "pi-coding-agent";
  version = "1.6.1";

  src = fetchurl {
    url = "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-${finalAttrs.version}.tgz";
    hash = "sha256-47DrVLbh6Vtg7HxCBJWb1prcUfsfDaOllDC7yaWTc08=";
  };

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-/rwNksFPbL4KqpTNRKeJSyXb5h6UxCI16ONhLKbVr9s=";

  inherit nodejs;
  dontNpmBuild = true;
  # Its install scripts are the native optional deps (kerberos, bufferutil),
  # none of which pi needs to run.
  npmFlags = ["--ignore-scripts"];
  npmInstallFlags = ["--omit=dev"];

  passthru.updateScript = nix-update-script {extraArgs = ["--generate-lockfile"];};

  meta = {
    description = "pi, a minimal coding agent harness";
    homepage = "https://pi.dev";
    license = lib.licenses.mit;
    mainProgram = "pi";
  };
})
