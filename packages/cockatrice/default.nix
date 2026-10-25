{
  lib,
  stdenv,
  qt6,
  cmake,
  protobuf,
  openssl,
  fetchFromGitHub,
  nix-update-script,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "cockatrice";
  # nixpkgs' cockatrice lags a full major version behind (2.10.x), so we build
  # from source. Cockatrice tags every build YYYY-MM-DD-{Release,Development}-X.Y.Z;
  # the `version` here is the full stable *Release* tag, so nix-update runs
  # against a regex that only matches Release tags: the atom feed it reads has
  # no prerelease flag to filter on. That feed only carries the 10 newest tags,
  # and upstream cuts Development betas far more often than Releases, so during
  # a beta streak there is no Release in the window and the bump errors out
  # with nothing to match. That's a red update run, not a broken package; it
  # clears itself once upstream cuts the next Release.
  version = "2026-10-25-Release-3.1.2";

  src = fetchFromGitHub {
    owner = "Cockatrice";
    repo = "Cockatrice";
    tag = finalAttrs.version;
    hash = "sha256-qrYq+jvhBbpTjT7KT5is7wnRVBJ8eaPYCUZLnPtP3l4=";
  };

  nativeBuildInputs = [
    cmake
    qt6.wrapQtAppsHook
    qt6.qttools
  ];

  buildInputs = [
    qt6.qtbase
    qt6.qtmultimedia
    qt6.qtsvg
    qt6.qtwebsockets
    qt6.qtimageformats
    protobuf
    openssl
  ];

  passthru.updateScript = nix-update-script {
    extraArgs = ["--version-regex" "^(\\d{4}-\\d{2}-\\d{2}-Release-[0-9.]+)$"];
  };

  meta = {
    homepage = "https://github.com/Cockatrice/Cockatrice";
    description = "Cross-platform virtual tabletop for multiplayer card games";
    license = lib.licenses.gpl2Plus;
    maintainers = with lib.maintainers; [evanjs];
    platforms = with lib.platforms; linux;
    mainProgram = "cockatrice";
  };
})
