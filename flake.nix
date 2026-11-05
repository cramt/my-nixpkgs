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
            runtimeInputs = [pkgs.curl pkgs.git pkgs.gnugrep pkgs.jq pkgs.nix pkgs.nodejs_24];
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

    nixosModules.t3code = import ./modules/t3code.nix self;

    # A sample host using every part of the t3code module, evaluated against
    # this nixpkgs: the build runs `t3 policy check` on the policy and renders
    # the seed script, the reconciler spec and both user units.
    checks = lib.genAttrs systems (system: {
      t3code-module = let
        host = lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.t3code
            {
              boot.isContainer = true;
              system.stateVersion = "26.05";
              users.users.alice.isNormalUser = true;
              services.t3code = {
                enable = true;
                user = "alice";
                sharedSecretFile = "/run/secrets/t3code";
                providers.codex = false;
                customModels.claudeAgent = [{slug = "example/model";}];
                settings.continueThreadsAfterServerUpdate = true;
                secretSettings."usageLimitSources.cliproxy.managementKey" = "/run/secrets/cliproxy";
                policy.settings.defaultRuntimeMode = {
                  value = "auto-accept-edits";
                  locked = false;
                };
                devices = {
                  enable = true;
                  simlock = {
                    enable = true;
                    hosts.lab = {
                      gatewayUrl = "https://lab.example:4700";
                      agentTokenFile = "/run/secrets/simlock";
                    };
                  };
                };
                projects.website = {
                  workspaceRoot = "/home/alice/website";
                  settings.autoPull = true;
                };
                scheduledTasks = {
                  morning = {
                    prompt = "Summarise yesterday's commits.";
                    project = "/home/alice/website";
                    schedule.daily = {
                      timeOfDay = "07:30";
                      weekdays = [1 2 3 4 5];
                    };
                    model.model = "claude-sonnet-5-5";
                  };
                  hourly = {
                    prompt = "Check the deploy.";
                    project = "/home/alice/website";
                    schedule.interval.minutes = 60;
                    model.model = "claude-haiku-5-5";
                    workspace.worktree.baseRef = "main";
                  };
                };
              };
            }
          ];
        };
        inherit (host) config;
        pkgs = nixpkgs.legacyPackages.${system};
      in
        assert lib.assertMsg (builtins.all (a: a.assertion) config.assertions) "t3code-module: an assertion failed";
          pkgs.linkFarm "t3code-module-check" {
            "policy.json" = config.environment.etc."t3code/policy.json".source;
            "t3code.service" = config.systemd.user.units."t3code.service".unit;
            "t3code-declare.service" = config.systemd.user.units."t3code-declare.service".unit;
          };
    });

    # Bare `nix fmt` passes no paths, and alejandra then waits on stdin.
    formatter =
      forAllSystems (pkgs:
        pkgs.writeShellScriptBin "fmt" ''exec ${lib.getExe pkgs.alejandra} "''${@:-.}"'');
  };
}
