{
  nix-update-script,
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
# Charge limiter daemon for Apple Silicon MacBooks, following the Homebrew
# formula (Formula/b/batt.rb). Only the binary: the consumer owns the launchd
# daemon and /etc/batt.json (re-zip/infra-office-servers' laptop.nix).
buildGoModule (finalAttrs: {
  pname = "batt";
  version = "0.9.0";

  src = fetchFromGitHub {
    owner = "charlie0129";
    repo = "batt";
    tag = "v${finalAttrs.version}";
    hash = "sha256-qlBGIXNY/Su4XDqlBvT4JWHiL4+JEIL7NcBUjCLt678=";
  };

  vendorHash = "sha256-v3YSYAn+tL5ZfuPq8OD1QvDZKOWRD3T2ts2wPxuKMEc=";

  subPackages = ["cmd/batt"];
  # Same tag Homebrew builds with: drops `batt install`/`uninstall`, which would
  # write their own launchd plist next to the consumer's
  tags = ["brew"];
  ldflags = [
    "-s"
    "-w"
    "-X github.com/charlie0129/batt/pkg/version.Version=v${finalAttrs.version}"
  ];

  # The tests poke the SMC, which the build sandbox has no access to
  doCheck = false;

  passthru.updateScript = nix-update-script {};

  meta = {
    description = "Control and limit battery charging on Apple Silicon MacBooks";
    homepage = "https://github.com/charlie0129/batt";
    license = lib.licenses.gpl2Only;
    platforms = ["aarch64-darwin"];
    mainProgram = "batt";
  };
})
