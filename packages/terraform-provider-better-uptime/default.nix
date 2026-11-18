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
  pname = "terraform-provider-better-uptime";
  version = "0.22.5";

  src = fetchFromGitHub {
    owner = "BetterStackHQ";
    repo = "terraform-provider-better-uptime";
    tag = "v${finalAttrs.version}";
    hash = "sha256-EOxRcq7ridgiJAYN3hOJ7jZ9rI+VuCfVZHBMVjOL8V4=";
  };

  vendorHash = "sha256-gtFZibSCELwy7lB3owPnzEwxJxp7qS7snET75qE0Rho=";

  subPackages = ["."];
  doCheck = false;
  # Registry builds disable cgo, and so does mkProvider.
  env.CGO_ENABLED = 0;
  ldflags = ["-s" "-w" "-X main.version=${finalAttrs.version}"];

  postInstall = ''
    dir=$out/libexec/terraform-providers/${finalAttrs.passthru.provider-source-address}/${finalAttrs.version}/''${GOOS}_''${GOARCH}
    mkdir -p "$dir"
    mv $out/bin/* "$dir/terraform-provider-better-uptime_${finalAttrs.version}"
    rmdir $out/bin
  '';

  passthru = {
    provider-source-address = "registry.terraform.io/BetterStackHQ/better-uptime";
    updateScript = nix-update-script {};
  };

  meta = {
    homepage = "https://registry.terraform.io/providers/BetterStackHQ/better-uptime";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };
})
