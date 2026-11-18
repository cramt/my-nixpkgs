{
  lib,
  buildGoLatestModule,
  go_latest,
  fetchurl,
  fetchFromGitHub,
  nix-update-script,
}: let
  # go.mod asks for go >= 1.27.4, newer than nixpkgs' go_latest. The check stops
  # overriding once nixpkgs catches up; drop it then.
  go =
    if lib.versionAtLeast go_latest.version "1.27.4"
    then go_latest
    else
      go_latest.overrideAttrs {
        version = "1.27.4";
        src = fetchurl {
          url = "https://go.dev/dl/go1.27.4.src.tar.gz";
          hash = "sha256-c8+4VxrsDAEXdofbhxY9Rqog6XeWcncokaoXZU2aYJk=";
        };
      };
in
  # The layout nixpkgs' terraform-providers.mkProvider produces, so
  # opentofu.withPlugins takes it. Not mkProvider itself: nix-update edits the file
  # a package is defined in, and that would be nixpkgs'.
  (buildGoLatestModule.override {inherit go;}) (finalAttrs: {
    pname = "terraform-provider-posthog";
    version = "1.0.31";

    src = fetchFromGitHub {
      owner = "PostHog";
      repo = "terraform-provider-posthog";
      tag = "v${finalAttrs.version}";
      hash = "sha256-S3Zeefs56hsRIa9rfgG5ZD9N+Dzw2B+s03qVr1KppHE=";
    };

    # The repo commits its vendor/ directory.
    vendorHash = null;

    subPackages = ["."];
    doCheck = false;
    # Registry builds disable cgo, and so does mkProvider.
    env.CGO_ENABLED = 0;
    ldflags = ["-s" "-w" "-X main.version=${finalAttrs.version}"];

    postInstall = ''
      dir=$out/libexec/terraform-providers/${finalAttrs.passthru.provider-source-address}/${finalAttrs.version}/''${GOOS}_''${GOARCH}
      mkdir -p "$dir"
      mv $out/bin/* "$dir/terraform-provider-posthog_${finalAttrs.version}"
      rmdir $out/bin
    '';

    passthru = {
      provider-source-address = "registry.terraform.io/PostHog/posthog";
      updateScript = nix-update-script {};
    };

    meta = {
      homepage = "https://registry.terraform.io/providers/PostHog/posthog";
      license = lib.licenses.mpl20;
      platforms = lib.platforms.linux;
    };
  })
