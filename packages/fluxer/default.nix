{
  lib,
  appimageTools,
  fetchurl,
}:
# Fluxer's desktop client isn't in nixpkgs, and the from-source build lives in a
# monorepo alongside the whole backend, so wrap the official AppImage.
# version + hash live in sources.json, rewritten by `nix run .#update -- fluxer`.
let
  pname = "fluxer";
  sources = lib.importJSON ./sources.json;
  inherit (sources) version;

  src = fetchurl {
    url = "https://github.com/fluxerapp/fluxer/releases/download/fluxer-desktop-stable%40${version}/Fluxer-${version}-linux-x86_64.AppImage";
    inherit (sources) hash;
  };

  extracted = appimageTools.extract {inherit pname version src;};
in
  appimageTools.wrapType2 {
    inherit pname version src;

    # The upstream entry points at AppRun and /opt/Fluxer, neither of which exist
    # once wrapped.
    extraInstallCommands = ''
      install -Dm444 ${extracted}/app.fluxer.FluxerDesktop.desktop -t $out/share/applications
      substituteInPlace $out/share/applications/app.fluxer.FluxerDesktop.desktop \
        --replace-fail 'Exec=AppRun' 'Exec=${pname}' \
        --replace-fail '"/opt/Fluxer/fluxer"' '${pname}'
      cp -r ${extracted}/usr/share/icons $out/share
    '';

    meta = {
      description = "Free and open source instant messaging and VoIP chat app";
      homepage = "https://fluxer.app";
      license = lib.licenses.agpl3Only;
      mainProgram = "fluxer";
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      platforms = ["x86_64-linux"];
    };
  }
