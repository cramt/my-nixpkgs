{
  description = "Packages nixpkgs lacks or lags on, kept current by CI";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    lib = nixpkgs.lib;
    systems = ["x86_64-linux" "aarch64-linux"];

    # Every packages/<name>/ is pkgs.<name>; dropping the folder in is the whole
    # registration. A folder named after a nixpkgs attribute shadows it.
    entries = builtins.readDir ./packages;
    names = builtins.filter (n: entries.${n} == "directory") (builtins.attrNames entries);

    forAllSystems = f:
      lib.genAttrs systems (system:
        f (import nixpkgs {
          inherit system;
          # zed-delta and steamlink are unfree. This only covers the flake's own
          # outputs; the overlay follows whatever the consumer's config says.
          config.allowUnfree = true;
          overlays = [self.overlays.default];
        }));
  in {
    overlays.default = final: _prev:
      lib.genAttrs names (name: final.callPackage ./packages/${name} {});

    packages = forAllSystems (pkgs:
      lib.filterAttrs (_: lib.meta.availableOn pkgs.stdenv.hostPlatform)
      (lib.genAttrs names (name: pkgs.${name}))
      # rhystic-tracker's UnityPy stack, none of it in nixpkgs. Not in the
      # overlay (only rhystic-tracker's wrapper wants it), but each one is a
      # package here so it gets an updater like everything else.
      // import ./packages/rhystic-tracker/python {inherit (pkgs) python3Packages;});

    # `nix run .#update` bumps every package that has an updater,
    # `nix run .#update -- <name>...` just those, `--list` prints their names.
    # A package's updater is its packages/<name>/update.sh if it has one (run
    # from the repo root with its sources.json), else its nix-update-script
    # passthru.updateScript run against this flake. No updater, no bumps.
    apps = forAllSystems (pkgs: let
      updaters = lib.filterAttrs (_: cmd: cmd != null) (lib.mapAttrs (name: pkg:
        if builtins.pathExists ./packages/${name}/update.sh
        then let
          script = pkgs.writeShellApplication {
            name = "update-${name}";
            runtimeInputs = [pkgs.curl pkgs.git pkgs.gnugrep pkgs.jq pkgs.nix];
            text = builtins.readFile ./packages/${name}/update.sh;
          };
        in "${lib.getExe script} packages/${name}/sources.json"
        else if builtins.isList (pkg.updateScript or null)
        then lib.escapeShellArgs (pkg.updateScript ++ ["--flake" name])
        else null)
      self.packages.${pkgs.stdenv.hostPlatform.system});
    in {
      update = {
        type = "app";
        program = lib.getExe (pkgs.writeShellApplication {
          name = "update";
          text = ''
            if [ "''${1:-}" = --list ]; then
              echo ${lib.escapeShellArg (builtins.toJSON (builtins.attrNames updaters))}
              exit
            fi
            [ $# -gt 0 ] || set -- ${lib.escapeShellArgs (builtins.attrNames updaters)}

            failed=()
            for name in "$@"; do
              echo ">> $name"
              case "$name" in
                ${lib.concatStrings (lib.mapAttrsToList (name: cmd: ''
                ${lib.escapeShellArg name}) ${cmd} || failed+=("$name") ;;
              '')
              updaters)}
                *) echo "no updater for $name" >&2; failed+=("$name") ;;
              esac
            done

            if [ ''${#failed[@]} -gt 0 ]; then
              echo "failed: ''${failed[*]}" >&2
              exit 1
            fi
          '';
        });
      };
    });

    # Bare `nix fmt` passes no paths, and alejandra then waits on stdin.
    formatter =
      forAllSystems (pkgs:
        pkgs.writeShellScriptBin "fmt" ''exec ${lib.getExe pkgs.alejandra} "''${@:-.}"'');
  };
}
