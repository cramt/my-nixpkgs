{
  lib,
  buildGoLatestModule,
  fetchFromGitHub,
  nix-update-script,
}:
# The layout nixpkgs' terraform-providers.mkProvider produces, so
# opentofu.withPlugins takes it. Not mkProvider itself: nix-update edits the file
# a package is defined in, and that would be nixpkgs'.
buildGoLatestModule (finalAttrs: {
  pname = "terraform-provider-mimir";
  version = "1.2.0";

  src = fetchFromGitHub {
    owner = "fgouteroux";
    repo = "terraform-provider-mimir";
    tag = "v${finalAttrs.version}";
    hash = "sha256-qBZ6HuvV4HHuKBQjWy5VIsSB5QWLkY3jxUTgizk9D8c=";
  };

  vendorHash = "sha256-5f7ynv6HIRQpgIwA0EBx/VPqQIQf/5ljCd3XGxPMpzw=";

  subPackages = ["."];
  doCheck = false;
  # Registry builds disable cgo, and so does mkProvider.
  env.CGO_ENABLED = 0;
  ldflags = ["-s" "-w" "-X main.version=${finalAttrs.version}"];

  postInstall = ''
    dir=$out/libexec/terraform-providers/${finalAttrs.passthru.provider-source-address}/${finalAttrs.version}/''${GOOS}_''${GOARCH}
    mkdir -p "$dir"
    mv $out/bin/* "$dir/terraform-provider-mimir_${finalAttrs.version}"
    rmdir $out/bin
  '';

  passthru = {
    provider-source-address = "registry.terraform.io/fgouteroux/mimir";
    updateScript = nix-update-script {};
  };

  meta = {
    homepage = "https://registry.terraform.io/providers/fgouteroux/mimir";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };
})
