# PostHog's CLI (source map inject/upload, among others). nixpkgs doesn't have
# it, and the npm package's postinstall fetches a glibc-dynamic binary NixOS
# can't exec. Upstream's musl builds are static, so on Linux this is a tar
# extract, no patchelf. File names and hashes live in sources.json, rewritten
# by `nix run .#update -- posthog-cli`.
{
  lib,
  stdenv,
  fetchurl,
  versionCheckHook,
}: let
  sources = lib.importJSON ./sources.json;
  inherit (sources) version;
  system = stdenv.hostPlatform.system;
  file = sources.files.${system} or (throw "posthog-cli: no upstream build for ${system}");
in
  stdenv.mkDerivation {
    pname = "posthog-cli";
    inherit version;

    src = fetchurl {
      url = "https://github.com/PostHog/posthog/releases/download/posthog-cli/v${version}/${file}";
      hash = sources.hashes.${system};
    };

    installPhase = ''
      runHook preInstall
      install -D posthog-cli $out/bin/posthog-cli
      runHook postInstall
    '';

    # Upstream ships it unstripped with debug info (~120 MB); stripping a
    # static-pie is safe on Linux.
    dontStrip = stdenv.hostPlatform.isDarwin;

    doInstallCheck = true;
    nativeInstallCheckInputs = [versionCheckHook];

    meta = {
      description = "PostHog command-line tool";
      homepage = "https://github.com/PostHog/posthog/tree/master/cli";
      license = lib.licenses.mit;
      platforms = builtins.attrNames sources.files;
      mainProgram = "posthog-cli";
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  }
