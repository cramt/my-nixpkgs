# 1Password's CLI, `op`. Shadows nixpkgs' _1password-cli for two reasons:
# nixpkgs lags upstream, and it has no armv7l-linux source although upstream
# ships one (op_linux_arm). nixconf's secrets service runs `op read` on every
# host, venus (a 32-bit Zynq) included.
#
# Upstream builds are static Go binaries, so on Linux this is an unzip. The
# per-platform file names and hashes live in sources.json, rewritten by
# `nix run .#update -- _1password-cli`.
{
  lib,
  stdenv,
  fetchurl,
  unzip,
  xar,
  cpio,
  installShellFiles,
  versionCheckHook,
}: let
  sources = lib.importJSON ./sources.json;
  inherit (sources) version;
  system = stdenv.hostPlatform.system;
  file = builtins.replaceStrings ["@version@"] [version] (sources.files.${system} or (throw "1password-cli: no upstream build for ${system}"));
in
  stdenv.mkDerivation {
    pname = "1password-cli";
    inherit version;

    src = fetchurl {
      url = "https://cache.agilebits.com/dist/1P/op2/pkg/v${version}/${file}";
      hash = sources.hashes.${system};
    };

    nativeBuildInputs =
      [installShellFiles]
      ++ lib.optional stdenv.hostPlatform.isLinux unzip
      ++ lib.optionals stdenv.hostPlatform.isDarwin [xar cpio];

    unpackPhase =
      if stdenv.hostPlatform.isDarwin
      then ''
        xar -xf $src
        zcat op.pkg/Payload | cpio -i
      ''
      else ''
        unzip $src op
      '';

    installPhase = ''
      runHook preInstall
      install -D op $out/bin/op
      runHook postInstall
    '';

    # Completions come from running op, which a cross build (venus) can't.
    postInstall = lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
      HOME=$TMPDIR
      installShellCompletion --cmd op \
        --bash <($out/bin/op completion bash) \
        --fish <($out/bin/op completion fish) \
        --zsh <($out/bin/op completion zsh)
    '';

    dontStrip = stdenv.hostPlatform.isDarwin;

    doInstallCheck = true;
    nativeInstallCheckInputs = [versionCheckHook];

    meta = {
      description = "1Password command-line tool";
      homepage = "https://developer.1password.com/docs/cli/";
      license = lib.licenses.unfree;
      platforms = builtins.attrNames sources.files;
      mainProgram = "op";
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  }
