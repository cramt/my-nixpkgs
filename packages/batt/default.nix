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
  version = "0.10.0";

  src = fetchFromGitHub {
    owner = "charlie0129";
    repo = "batt";
    tag = "v${finalAttrs.version}";
    hash = "sha256-B1NYASaMCI31PSwOS4kVOomvAO9Y+V0G1o6eC3He9YA=";
  };

  vendorHash = "sha256-TOZHFQ1xlHmExeV2VYu7ex7M3p0J+jbmbrgzjPPomoY=";

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
