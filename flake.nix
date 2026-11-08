{
  description = "Packages nixpkgs lacks or lags on, kept current by CI";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    lib = nixpkgs.lib;
    # Linux is home. Darwin is opt-in per package: most of these leave
    # meta.platforms unset or have never been near a Mac, and building them all
    # on the macOS CI leg would turn every bump red. Only packages that name a
    # darwin platform themselves (batt) show up there.
    linuxSystems = ["x86_64-linux" "aarch64-linux"];
    systems = linuxSystems ++ ["aarch64-darwin"];
    optedIntoDarwin = pkg: builtins.any (lib.hasSuffix "-darwin") (pkg.meta.platforms or []);

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

    packages = forAllSystems (pkgs: let
      available = lib.filterAttrs (_: lib.meta.availableOn pkgs.stdenv.hostPlatform) (lib.genAttrs names (name: pkgs.${name}));
    in
      if pkgs.stdenv.hostPlatform.isDarwin
      then lib.filterAttrs (_: optedIntoDarwin) available
      else
        available
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
    # Darwin gets an empty set rather than none, since CI looks up checks.<system>.
    checks = lib.genAttrs systems (system:
      lib.optionalAttrs (lib.elem system linuxSystems) {
        t3code-module = let
          host = lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.t3code
              {
                boot.isContainer = true;
                system.stateVersion = "26.05";
                users.users.alice.isNormalUser = true;
                # The default per-site log under /var/log is unopenable in the
                # sandbox, where the check runs `caddy validate`.
                services.caddy.virtualHosts."alice.ts.example.com".logFormat = "output discard";
                services.t3code = {
                  enable = true;
                  user = "alice";
                  sharedSecretFile = "/run/secrets/t3code";
                  providers.codex = false;
                  customModels.claudeAgent = [{slug = "example/model";}];
                  settings.continueThreadsAfterServerUpdate = true;
                  secretSettings."usageLimitSources.cliproxy.managementKey" = "/run/secrets/cliproxy";
                  linkedEnvironments = {
                    enable = true;
                    peers.desk = {
                      urls = ["https://t3.desk.example" "http://desk.tail1234.ts.net:3773"];
                      pairingCodeFile = "/run/secrets/t3code";
                      access = "full-access";
                    };
                  };
                  trustTailnet = {
                    enable = true;
                    virtualHost = "alice.ts.example.com";
                    excludeRanges = ["100.64.0.3/32"];
                  };
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
                  speech = {
                    model = "handy-computer/parakeet-unified-en-0.6b-gguf";
                    extraModels = ["handy-computer/moonshine-tiny-gguf"];
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
          # Checked by name, not built: building the links would download the models.
          assert lib.assertMsg (let
            links = lib.attrNames config.systemd.tmpfiles.settings."10-t3code-speech";
          in
            lib.all (f: lib.elem "/home/alice/.t3/userdata/speech/models/${f}" links) [
              "parakeet-unified-en-0.6b-Q8_0.gguf"
              "moonshine-tiny-Q8_0.gguf"
              "silero-vad-v6.2-F32.gguf"
            ]) "t3code-module: speech models aren't linked into the model folder";
            pkgs.linkFarm "t3code-module-check" {
              "policy.json" = config.environment.etc."t3code/policy.json".source;
              "t3code.service" = config.systemd.user.units."t3code.service".unit;
              "t3code-declare.service" = config.systemd.user.units."t3code-declare.service".unit;
              "t3code-link-peers.service" = config.systemd.user.units."t3code-link-peers.service".unit;
              "t3code-tailnet-token.service" = config.systemd.units."t3code-tailnet-token.service".unit;
              # caddy fmt alone accepts unknown directives; validate provisions
              # the matcher and placeholder, so a bad trustTailnet site fails here.
              "Caddyfile" = pkgs.runCommand "t3code-module-caddy-validate" {} ''
                export HOME=$TMPDIR XDG_DATA_HOME=$TMPDIR XDG_CONFIG_HOME=$TMPDIR
                ${lib.getExe config.services.caddy.package} validate --adapter caddyfile --config ${config.services.caddy.configFile}
                cp ${config.services.caddy.configFile} $out
              '';
            };
      });

    # Bare `nix fmt` passes no paths, and alejandra then waits on stdin.
    formatter =
      forAllSystems (pkgs:
        pkgs.writeShellScriptBin "fmt" ''exec ${lib.getExe pkgs.alejandra} "''${@:-.}"'');
  };
}
