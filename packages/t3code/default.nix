# T3 Code (https://t3.codes), built from source at upstream's nightly tags.
#
# Started as numtide/llm-agents.nix's packages/t3code/unwrapped.nix, which only
# tracks stable tags and pins its own nixpkgs. Differences from there:
#  - Built against the consumer's nixpkgs, so electron and its glibc match the
#    host's mesa (llm-agents' electron can't dlopen /run/opengl-driver on a
#    newer system: "GLIBC_2.43 not found").
#  - No provider wrapper: the agents t3code spawns (claude, codex, ...) come
#    from the user's PATH with their own config and auth, not a second copy
#    baked into this closure.
#  - The reusable dev auth token is ungated (see postPatch).
#  - nixpkgs' autoPatchelfHook and versionCheckHook stand in for llm-agents'
#    formatelf and versionCheckHomeHook.
#
# version + hashes live in sources.json, rewritten by `nix run .#update -- t3code`.
{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchPnpmDeps,
  pnpm_11,
  pnpmConfigHook,
  pnpmBuildHook,
  nodejs_24,
  node-gyp,
  pkg-config,
  autoPatchelfHook,
  libsecret,
  python3,
  cacert,
  electron_44,
  makeBinaryWrapper,
  installShellFiles,
  makeDesktopItem,
  rustPlatform,
  versionCheckHook,
}: let
  sources = lib.importJSON ./sources.json;
  inherit (sources) version;
  pname = "t3code";
  pnpm = pnpm_11;
  electron = electron_44;

  src = fetchFromGitHub {
    owner = "pingdotgg";
    repo = "t3code";
    tag = "v${version}";
    inherit (sources) hash;
  };

  # The web build's third-party-licenses vite plugin downloads SPDX license
  # texts unless they are already cached under .generated/. update.sh reads
  # the rev from SPDX_LICENSE_LIST_REVISION in scripts/lib/third-party-licenses.ts.
  spdxLicenses = fetchFromGitHub {
    owner = "spdx";
    repo = "license-list-data";
    inherit (sources.spdx) rev hash;
    sparseCheckout = ["json/details"];
  };

  resourceMonitor = rustPlatform.buildRustPackage {
    pname = "t3code-resource-monitor";
    inherit version src;

    sourceRoot = "${src.name}/native/resource-monitor";
    # inspects the test process's own RSS via procfs, 0 on some builders
    checkFlags = ["--skip=tests::loads_details_when_an_existing_process_becomes_selected"];
    inherit (sources) cargoHash;
  };

  platformKey =
    {
      x86_64-linux = "linux-x64";
      aarch64-linux = "linux-arm64";
    }
    .${
      stdenv.hostPlatform.system
    };

  pnpmWorkspaces = [
    "@t3tools/monorepo"
    "t3..."
    "@t3tools/desktop..."
    "@t3tools/scripts..."
  ];

  appName = "T3 Code (Alpha)";
  desktopIcon = "assets/prod/black-universal-1024.png";

  desktopItem = makeDesktopItem {
    name = "t3code";
    desktopName = appName;
    comment = "Control surface for coding agents";
    exec = "t3code-desktop %U";
    icon = "t3code";
    categories = ["Development"];
    startupWMClass = "t3code";
  };
in
  stdenv.mkDerivation {
    inherit
      pname
      version
      src
      pnpmWorkspaces
      ;

    outputs = [
      "out"
      "desktop"
    ];

    strictDeps = true;
    __structuredAttrs = true;

    # Public production identifiers, also embedded in upstream release builds.
    # loadRepoEnv supplies the corresponding VITE_* values for the web frontend.
    env = {
      T3CODE_RELAY_URL = "https://relay.t3.codes";
      T3CODE_CLERK_PUBLISHABLE_KEY = "pk_live_Y2xlcmsudDMuY29kZXMk";
      T3CODE_CLERK_CLI_OAUTH_CLIENT_ID = "hzxSgY2cH10sDU2r";
    };

    pnpmDeps = fetchPnpmDeps {
      inherit
        pnpm
        pname
        version
        src
        pnpmWorkspaces
        ;
      fetcherVersion = 4;
      hash = sources.pnpmDepsHash;
    };

    nativeBuildInputs = [
      autoPatchelfHook
      cacert
      installShellFiles
      makeBinaryWrapper
      node-gyp
      nodejs_24
      pkg-config
      pnpm
      pnpmBuildHook
      pnpmConfigHook
      python3
    ];

    # build:desktop compiles native/browser-secret against libsecret
    buildInputs = [
      libsecret
      stdenv.cc.cc.lib
    ];

    postPatch = ''
      # We run electron on an unpacked tree, so app.isPackaged is false and the
      # backend would treat the store path as the workspace root
      # (https://github.com/numtide/llm-agents.nix/issues/9182).
      substituteInPlace apps/desktop/src/app/DesktopEnvironment.ts \
        --replace-fail "backendCwd: input.isPackaged ? homeDirectory : appRoot," "backendCwd: homeDirectory,"

      # Upstream's reusable dev token (T3CODE_DEV_AUTH_TOKEN) only switches on
      # alongside --dev-url, and that flag drags in dev behaviour a deployed
      # server doesn't want: loopback-Host requests 302 to the dev server (which
      # breaks the desktop app's SSH reuse probe, so it launches a second server
      # on the same ~/.t3), and Codex's ChatGPT login returns there. Ungated, it
      # is a plain fixed pairing secret, and still off unless the env var is
      # set. Drop this once upstream has a supported way:
      # https://github.com/pingdotgg/t3code/discussions/6750 (the unsafe-no-auth
      # PR #13001 was closed pending it).
      substituteInPlace apps/server/src/cli/config.ts \
        --replace-fail \
          'mode === "web" && devUrl !== undefined ? yield* DevAuthTokenConfig' \
          'mode === "web" ? yield* DevAuthTokenConfig'
      substituteInPlace apps/server/src/auth/ReusableDevAuth.ts \
        --replace-fail \
          'config.mode !== "web" || config.devUrl === undefined ||' \
          'config.mode !== "web" ||'

      spdxRev=$(sed -n 's/^const SPDX_LICENSE_LIST_REVISION = "\(.*\)";/\1/p' scripts/lib/third-party-licenses.ts)
      if [[ "$spdxRev" != "${spdxLicenses.rev}" ]]; then
        echo "error: upstream pins SPDX license-list-data $spdxRev, rerun update.sh" >&2
        exit 1
      fi
      spdxVer=$(sed -n 's/^const SPDX_LICENSE_LIST_VERSION = "\(.*\)";/\1/p' scripts/lib/third-party-licenses.ts)
      mkdir -p .generated/third-party-licenses/spdx
      ln -s ${spdxLicenses}/json/details ".generated/third-party-licenses/spdx/$spdxVer"
    '';

    preBuild = ''
      export pnpm_config_verify_deps_before_run=false

      node scripts/update-release-package-versions.ts ${version}

      # Fail loudly rather than run upstream's app on an electron it outgrew.
      upstream_electron=$(node -p "require('./apps/desktop/package.json').dependencies.electron")
      upstream_major=''${upstream_electron#^}
      upstream_major=''${upstream_major%%.*}
      nix_major=${lib.versions.major electron.version}
      if (( upstream_major > nix_major )); then
        echo "error: upstream expects Electron $upstream_electron but nixpkgs provides ${electron.version}" >&2
        exit 1
      fi

      export npm_config_nodedir=${nodejs_24}
      export ELECTRON_SKIP_BINARY_DOWNLOAD=1
      pnpm rebuild --pending "''${pnpmInstallFlags[@]}" \
        --filter '!@t3tools/monorepo'
    '';

    pnpmBuildScript = "build:desktop";

    # Dependencies include prebuilt artifacts for foreign systems and statically
    # linked executables, which must not be patched or audited as host binaries.
    dontPatchELF = true;
    dontAutoPatchelf = true;
    noAuditTmpdir = true;

    installPhase = ''
      runHook preInstall

      # Deploy isolated production graphs instead of the whole workspace store.
      pnpm --filter t3 deploy --prod --offline "$out/libexec/t3code/apps/server"

      mkdir -p "$out/libexec/t3code/apps/server/dist/resource-monitor/${platformKey}"
      install -Dm755 ${resourceMonitor}/bin/t3-resource-monitor \
        "$out/libexec/t3code/apps/server/dist/resource-monitor/${platformKey}/t3-resource-monitor"

      mkdir -p "$out/bin"
      makeWrapper ${lib.getExe nodejs_24} "$out/bin/t3" \
        --add-flags "$out/libexec/t3code/apps/server/dist/bin.mjs"

      pnpm --filter @t3tools/desktop deploy --prod --offline "$desktop/libexec/t3code/apps/desktop"
      cp -r --no-preserve=mode apps/desktop/dist-electron "$desktop/libexec/t3code/apps/desktop/"
      mkdir -p "$desktop/libexec/t3code/apps/desktop/prod-resources"
      install -Dm444 ${desktopIcon} \
        "$desktop/libexec/t3code/apps/desktop/prod-resources/icon.png"

      ln -s "$out/libexec/t3code/apps/server" "$desktop/libexec/t3code/apps/server"

      mkdir -p "$desktop/libexec/t3code/apps/desktop/prod-resources/resource-monitor"
      ln -s \
        "$out/libexec/t3code/apps/server/dist/resource-monitor/${platformKey}/t3-resource-monitor" \
        "$desktop/libexec/t3code/apps/desktop/prod-resources/resource-monitor/t3-resource-monitor"

      install -Dm755 native/browser-secret/build/${stdenv.hostPlatform.node.arch}/t3-browser-secret \
        "$desktop/libexec/t3code/apps/desktop/prod-resources/browser-secret/t3-browser-secret"

      find "$out/libexec/t3code" "$desktop/libexec/t3code" -xtype l -delete

      mkdir -p "$desktop/bin"
      makeWrapper ${lib.getExe electron} "$desktop/bin/t3code-desktop" \
        --add-flags "$desktop/libexec/t3code/apps/desktop" \
        --inherit-argv0

      mkdir -p "$desktop/share/icons/hicolor/scalable/apps"
      install -Dm444 ${desktopIcon} "$desktop/share/icons/t3code.png"
      install -Dm444 assets/prod/logo.svg "$desktop/share/icons/hicolor/scalable/apps/t3code.svg"
      cp -r ${desktopItem}/share/applications "$desktop/share/"

      runHook postInstall
    '';

    # Electron, unlike node, does not already have libstdc++ loaded for the
    # prebuilt pty.node (https://github.com/numtide/llm-agents.nix/issues/10125).
    postFixup = ''
      autoPatchelf "$out/libexec/t3code/apps/server/node_modules/node-pty/prebuilds/${platformKey}"
    '';

    postInstall = ''
      for shell in bash fish zsh; do
        installShellCompletion --cmd t3 --"$shell" <("$out/bin/t3" --completions "$shell")
      done
    '';

    # t3 writes under $HOME even for --version, and the sandbox's is unwritable.
    preInstallCheck = ''
      export HOME=$(mktemp -d)
    '';
    doInstallCheck = true;
    nativeInstallCheckInputs = [versionCheckHook];
    versionCheckKeepEnvironment = ["HOME"];
    versionCheckProgramArg = ["--version"];

    passthru = {
      inherit appName resourceMonitor spdxLicenses;
    };

    meta = {
      description = "Control surface for coding agents";
      homepage = "https://t3.codes";
      changelog = "https://github.com/pingdotgg/t3code/releases/tag/v${version}";
      license = lib.licenses.mit;
      sourceProvenance = [lib.sourceTypes.fromSource];
      mainProgram = "t3";
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    };
  }
