# T3 Code as a NixOS service, configured from Nix as far as upstream allows:
#  - the server, as a `systemd --user` unit of a real login user, so the
#    agents it spawns inherit that user's environment (git, ssh, agent CLIs)
#  - settings.json: `settings` and `secretSettings` are merged in on every
#    start, everything else in the file stays UI-owned
#  - /etc/t3code/policy.json, upstream's managed policy: defaults and locks
#    for every T3 Code on the host, the desktop app's included, checked by
#    this build's own `t3 policy check` so a bad policy fails the build
#  - the Device panel's npm tools, linked in from the store
#  - projects and scheduled tasks, applied to the running server by
#    t3code-declare after every start (see packages/t3code-declare)
#
# The user unit is a NixOS one (/etc/systemd/user), so switch-to-configuration
# restarts it when it changes.
self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.t3code;
  json = pkgs.formats.json {};
  ours = self.overlays.default pkgs pkgs;
  t3 = lib.getExe' cfg.package "t3";
  stateDir = "${cfg.dataDir}/userdata";
  settingsFile = "${stateDir}/settings.json";

  # Every driver t3code ships. Unknown driver envelopes are preserved verbatim
  # upstream, so a typo'd key would otherwise sit in settings.json as a
  # phantom provider with nothing complaining.
  knownDrivers = ["codex" "claudeAgent" "cursor" "grok" "opencode"];
  declaredDrivers = lib.unique (lib.attrNames cfg.providers ++ lib.attrNames cfg.customModels);

  # Both shapes, because both are live upstream: `providers.<kind>` is the
  # legacy mirror the settings UI reads, `providerInstances.<kind>` the
  # envelope the registry resolves (and an explicit envelope wins). customModels
  # only goes in the envelope: upstream migrates the mirror once and then
  # ignores everything in it but `enabled`.
  providerSettings = lib.optionalAttrs (declaredDrivers != []) {
    providers = lib.mapAttrs (_: enabled: {inherit enabled;}) cfg.providers;
    providerInstances = lib.genAttrs declaredDrivers (driver:
      {inherit driver;}
      // lib.optionalAttrs (cfg.providers ? ${driver}) {enabled = cfg.providers.${driver};}
      // lib.optionalAttrs (cfg.customModels ? ${driver}) {
        config.customModels = map (lib.filterAttrs (_: v: v != null)) cfg.customModels.${driver};
      });
  };

  simlockHosts = cfg.devices.simlock.hosts;
  simlockSettings = lib.optionalAttrs (simlockHosts != {}) {
    simlockDeviceHosts = lib.mapAttrsToList (id: h: {
      kind = "simlock";
      inherit id;
      inherit (h) label gatewayUrl maxLeases maxLeaseMinutes;
    }) simlockHosts;
  };
  simlockSecrets = lib.listToAttrs (lib.imap0 (i: h: lib.nameValuePair "simlockDeviceHosts.${toString i}.agentToken" h.agentTokenFile)
    (lib.attrValues simlockHosts));

  declaredSettings = json.generate "t3code-settings.json" (lib.foldl' lib.recursiveUpdate {} [providerSettings simlockSettings cfg.settings]);
  allSecretSettings = simlockSecrets // cfg.secretSettings;

  seedSettings = pkgs.writeShellApplication {
    name = "t3code-seed-settings";
    runtimeInputs = [pkgs.coreutils pkgs.jq];
    text =
      ''
        install -d -m700 ${lib.escapeShellArg stateDir}
        # A file the server would reject is worth nothing (it falls back to
        # defaults and ignores it), so a parse failure starts from scratch
        # instead of failing the unit.
        if ! current=$(jq . ${lib.escapeShellArg settingsFile} 2>/dev/null); then
          current='{}'
        fi
        printf '%s' "$current" | jq --slurpfile declared ${declaredSettings} '. * $declared[0]' > ${lib.escapeShellArg "${settingsFile}.new"}
      ''
      + lib.concatStrings (lib.mapAttrsToList (path: file: ''
          # `test -s`: a secret not rendered yet is a failed start that
          # Restart= retries, not an empty value in settings.json.
          test -s ${lib.escapeShellArg file}
          jq --rawfile v ${lib.escapeShellArg file} \
            --argjson p ${lib.escapeShellArg (builtins.toJSON (map (s:
              if builtins.match "[0-9]+" s != null
              then lib.toInt s
              else s) (lib.splitString "." path)))} \
            'setpath($p; $v | rtrimstr("\n"))' ${lib.escapeShellArg "${settingsFile}.new"} > ${lib.escapeShellArg "${settingsFile}.tmp"}
          mv ${lib.escapeShellArg "${settingsFile}.tmp"} ${lib.escapeShellArg "${settingsFile}.new"}
        '')
        allSecretSettings)
      + ''
        mv ${lib.escapeShellArg "${settingsFile}.new"} ${lib.escapeShellArg settingsFile}
      '';
  };

  serve = pkgs.writeShellScript "t3code-serve" (
    lib.optionalString (cfg.sharedSecretFile != null) ''
      test -s ${lib.escapeShellArg cfg.sharedSecretFile}
      T3CODE_DEV_AUTH_TOKEN=$(< ${lib.escapeShellArg cfg.sharedSecretFile})
      export T3CODE_DEV_AUTH_TOKEN
    ''
    + "exec ${t3} serve ${lib.escapeShellArgs ["--host" cfg.host "--port" (toString cfg.port) "--base-dir" cfg.dataDir "--no-browser"]}\n"
  );

  policyDocument =
    {
      schemaVersion = 1;
      inherit (cfg.policy) organization settings;
    }
    // lib.optionalAttrs (cfg.policy.limits != {}) {inherit (cfg.policy) limits;};
  policyFile =
    pkgs.runCommand "t3code-policy.json" {
      raw = json.generate "t3code-policy-unchecked.json" policyDocument;
      nativeBuildInputs = [cfg.package];
    } ''
      export HOME=$TMPDIR
      t3 policy check "$raw"
      cp "$raw" $out
    '';
  lock = value: {
    inherit value;
    locked = true;
  };

  declareSpec = json.generate "t3code-declare.json" {
    origin = "http://127.0.0.1:${toString cfg.port}";
    baseDir = cfg.dataDir;
    t3 = t3;
    readyTimeoutSeconds = 120;
    projects = lib.mapAttrs (_: p: {
      inherit (p) workspaceRoot title createWorkspaceRootIfMissing settings;
    }) cfg.projects;
    scheduledTasks = lib.mapAttrs (_: t: {
      inherit (t) title prompt enabled runtimeMode interactionMode;
      project = t.project;
      schedule =
        if t.schedule ? interval
        then {
          type = "interval";
          everyMs = t.schedule.interval.minutes * 60000;
        }
        else if t.schedule ? daily
        then
          {
            type = "fixed_time";
            inherit (t.schedule.daily) timeOfDay;
          }
          // lib.optionalAttrs (t.schedule.daily.weekdays != null) {inherit (t.schedule.daily) weekdays;}
        else {
          type = "once";
          inherit (t.schedule.once) runAt;
        };
      modelSelection = lib.filterAttrs (_: v: v != null) t.model;
      workspaceStrategy =
        if t.workspace ? worktree
        then {type = "worktree";} // lib.filterAttrs (_: v: v != null) t.workspace.worktree
        else {type = "root";} // lib.filterAttrs (_: v: v != null) t.workspace.root;
    }) cfg.scheduledTasks;
  };

  # Attr names become ids (`nix:<name>`); the reconciler splits on ':'.
  idName = lib.types.strMatching "[A-Za-z0-9_-]+";
  modelType = lib.types.submodule {
    options = {
      instanceId = lib.mkOption {
        type = lib.types.str;
        default = "claudeAgent";
        description = "Provider instance; the driver kind for the built-in ones.";
      };
      model = lib.mkOption {
        type = lib.types.str;
        example = "claude-opus-5-5";
      };
      options = lib.mkOption {
        type = lib.types.nullOr json.type;
        default = null;
        description = "Provider-specific model options (effort and the like).";
      };
    };
  };
in {
  options.services.t3code = {
    enable = lib.mkEnableOption "the T3 Code server";

    package = lib.mkOption {
      type = lib.types.package;
      default = ours.t3code;
      defaultText = lib.literalExpression "my-nixpkgs' t3code";
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = ''
        Login user whose `systemd --user` manager runs the server. The agents
        it spawns run as this user, with its PATH. Lingering is turned on so
        the server starts at boot.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/${cfg.user}/.t3";
      defaultText = lib.literalExpression ''"/home/''${user}/.t3"'';
      description = "T3CODE_HOME. Created and owned from the system side, so it can sit on a bind mount.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
    };

    port = lib.mkOption {
      type = lib.types.port;
      # Upstream's own default.
      default = 3773;
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open `port`. Pairing tokens are the auth boundary.";
    };

    sharedSecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        File holding a fixed pairing secret (32+ characters), read at start.
        Every client can pair with it any number of times. Rides on
        upstream's reusable dev auth token, which this package ungates.
      '';
    };

    path = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/home/${cfg.user}/.nix-profile/bin"
        "/etc/profiles/per-user/${cfg.user}/bin"
        "/run/current-system/sw/bin"
        "/run/wrappers/bin"
        "/nix/var/nix/profiles/default/bin"
      ];
      defaultText = lib.literalMD "the user's profiles, then the system's";
      description = ''
        PATH for the server and every agent it spawns. Set explicitly because
        `systemd --user` doesn't reliably put the user's profile on it.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {T3CODE_OTLP_METRICS_URL = "http://127.0.0.1:4318/v1/metrics";};
    };

    preStart = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extra ExecStartPre commands, run as the user before settings are seeded.";
    };

    settings = lib.mkOption {
      type = json.type;
      default = {};
      example = {continueThreadsAfterServerUpdate = true;};
      description = ''
        Deep-merged into settings.json on every start: what's declared here
        wins, the rest of the file stays the UI's. Lists are replaced, not
        merged. For defaults the UI may change, or locks, use `policy`.
      '';
    };

    secretSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {"usageLimitSources.cliproxy.managementKey" = "/run/secrets/cliproxy-key";};
      description = ''
        Dot path into settings.json → file whose contents (trailing newline
        trimmed) go there on every start. Never copied into the store. Numeric
        segments index into lists.
      '';
    };

    providers = lib.mkOption {
      type = lib.types.attrsOf lib.types.bool;
      default = {};
      example = {codex = false;};
      description = "Turn coding-agent drivers on or off, keyed by driver kind.";
    };

    customModels = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf (lib.types.submodule {
        options = {
          slug = lib.mkOption {
            type = lib.types.str;
            description = "Model id handed to the agent CLI.";
          };
          name = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Label in the model picker; the slug when unset.";
          };
        };
      }));
      default = {};
      example = {claudeAgent = [{slug = "m365/gpt-5.5";}];};
      description = "Extra models in a driver's picker. Replaces that driver's custom models on every start.";
    };

    policy = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.enable;
        defaultText = lib.literalExpression "services.t3code.enable";
        description = ''
          Write /etc/t3code/policy.json. Machine-wide: the desktop app reads
          it too, so turn this on for a desktop-only host as well.
        '';
      };
      organization = lib.mkOption {
        type = lib.types.str;
        default = "NixOS";
        description = ''Shown as "Managed by <organization>" beside each locked control.'';
      };
      settings = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            value = lib.mkOption {
              type = json.type;
              description = "The value, as it would appear in settings.json.";
            };
            locked = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Pin it. false only replaces the built-in default.";
            };
          };
        });
        default = {};
        example = {
          defaultRuntimeMode = {
            value = "auto-accept-edits";
            locked = false;
          };
        };
        description = "Defaults and locks, keyed by dot path into settings.json.";
      };
      limits = lib.mkOption {
        type = json.type;
        default = {};
        example = {
          maxRuntimeMode = "auto";
          webhookTasks = false;
        };
        description = "Upstream's ManagedPolicyLimits; `t3 policy check` vets it at build time.";
      };
      homes = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            path = lib.mkOption {type = lib.types.str;};
            user = lib.mkOption {type = lib.types.str;};
          };
        });
        default = [];
        description = ''
          Every T3CODE_HOME on the host, so the Device panel's tools land in
          each. The server's own is added automatically; add the desktop app's
          if it runs from another one.
        '';
      };
    };

    devices = {
      enable = lib.mkEnableOption ''
        the Device panel (simulators and emulators), with its npm tools from
        the store rather than t3code's own `npm install`. On Linux the local
        source is Android emulators only (via ANDROID_HOME); remote sources
        (SSH hosts, EAS, Simlock) work without one
      '';
      agentAccess = lib.mkOption {
        type = lib.types.bool;
        default = cfg.devices.enable;
        defaultText = lib.literalExpression "devices.enable";
        description = "Let new agent sessions open and drive the devices.";
      };
      simlock = {
        enable = lib.mkEnableOption "Simlock device hosts (Labs, alpha)";
        hosts = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
            options = {
              label = lib.mkOption {
                type = lib.types.str;
                default = name;
              };
              gatewayUrl = lib.mkOption {
                type = lib.types.strMatching "https?://[^[:space:]/]+/?";
                example = "https://gateway.example.ts.net:4700";
              };
              agentTokenFile = lib.mkOption {
                type = lib.types.str;
                description = "File holding the gateway's agent token, readable by `user`.";
              };
              maxLeases = lib.mkOption {
                type = lib.types.ints.between 1 20;
                default = 2;
              };
              maxLeaseMinutes = lib.mkOption {
                type = lib.types.ints.between 5 240;
                default = 60;
              };
            };
          }));
          default = {};
          description = "Gateways the server leases from. While any are declared, hosts added in the UI are dropped on restart.";
        };
      };
    };

    projects = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
        options = {
          workspaceRoot = lib.mkOption {
            type = lib.types.str;
            example = "/home/alice/code/website";
          };
          title = lib.mkOption {
            type = lib.types.str;
            default = name;
          };
          createWorkspaceRootIfMissing = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          settings = lib.mkOption {
            type = lib.types.attrsOf json.type;
            default = {};
            example = {
              autoPull = true;
              pinned = true;
            };
            description = ''
              Fields of upstream's ProjectUpdatePayload (autoPull, pinned,
              scripts, defaultModelSelection, projectIcon, defaultThreadEnvMode),
              applied after every start. The server validates them.
            '';
          };
        };
      }));
      default = {};
      description = ''
        Projects to register, keyed by a name of [A-Za-z0-9_-]. A folder
        that's already registered is taken over in place. Dropping a
        declaration deletes a project this created (archives it if it has
        threads) and leaves one it took over alone.
      '';
    };

    scheduledTasks = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
        options = {
          title = lib.mkOption {
            type = lib.types.str;
            default = name;
          };
          prompt = lib.mkOption {type = lib.types.str;};
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          project = lib.mkOption {
            type = lib.types.str;
            description = "workspaceRoot of the project it runs in, declared or not.";
          };
          schedule = lib.mkOption {
            type = lib.types.attrTag {
              interval = lib.mkOption {
                type = lib.types.submodule {
                  options.minutes = lib.mkOption {type = lib.types.ints.positive;};
                };
              };
              daily = lib.mkOption {
                type = lib.types.submodule {
                  options = {
                    timeOfDay = lib.mkOption {
                      type = lib.types.strMatching "([01]?[0-9]|2[0-3]):[0-5][0-9]";
                      example = "07:30";
                      description = "Server-local time.";
                    };
                    weekdays = lib.mkOption {
                      type = lib.types.nullOr (lib.types.listOf (lib.types.ints.between 0 6));
                      default = null;
                      description = "0 is Sunday. Every day when null.";
                    };
                  };
                };
              };
              once = lib.mkOption {
                type = lib.types.submodule {
                  options.runAt = lib.mkOption {
                    type = lib.types.str;
                    example = "2026-12-24T18:00:00Z";
                  };
                };
              };
            };
            example = {daily.timeOfDay = "07:30";};
          };
          model = lib.mkOption {type = modelType;};
          runtimeMode = lib.mkOption {
            type = lib.types.enum ["approval-required" "auto-accept-edits" "auto" "full-access"];
            # Nobody is watching a scheduled run to approve anything.
            default = "full-access";
          };
          interactionMode = lib.mkOption {
            type = lib.types.enum ["default" "plan"];
            default = "default";
          };
          workspace = lib.mkOption {
            type = lib.types.attrTag {
              root = lib.mkOption {
                type = lib.types.submodule {
                  options.branch = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                  };
                };
              };
              worktree = lib.mkOption {
                type = lib.types.submodule {
                  options = {
                    baseRef = lib.mkOption {
                      type = lib.types.str;
                      example = "main";
                    };
                    branch = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                    };
                    startFromOrigin = lib.mkOption {
                      type = lib.types.nullOr lib.types.bool;
                      default = null;
                    };
                  };
                };
              };
            };
            default = {root = {};};
            description = "Where each run works: the project folder, or a fresh worktree.";
          };
        };
      }));
      default = {};
      description = ''
        Scheduled tasks, keyed by a name of [A-Za-z0-9_-]. Each run starts a
        new thread. Applied after every start; tasks made in the UI are left
        alone, and dropping a declaration deletes the task. Edits made in the
        UI to a declared task are reverted on the next restart.
      '';
    };
  };

  config = lib.mkMerge [
    {
      services.t3code.policy = {
        # The package owns the version: an in-app update would swap the store
        # build for upstream's npm one.
        limits.updates.mode = lib.mkDefault "off";
        settings = lib.mkMerge [
          (lib.mkIf cfg.devices.enable {
            enableDeviceSupport = lock true;
            # The onboarding flow's only job is enabling the hub, done above.
            deviceOnboardingCompleted = lock true;
          })
          {enableAgentDeviceAccess = lock cfg.devices.agentAccess;}
          {simlockDeviceHostsEnabled = lock cfg.devices.simlock.enable;}
        ];
        homes = lib.mkIf cfg.enable [
          {
            path = cfg.dataDir;
            inherit (cfg) user;
          }
        ];
      };
    }

    (lib.mkIf cfg.policy.enable {
      assertions = [
        {
          assertion = simlockHosts != {} -> cfg.devices.simlock.enable;
          message = "services.t3code.devices.simlock.hosts is ignored unless devices.simlock.enable is set.";
        }
        {
          assertion = !(simlockHosts ? local);
          message = ''services.t3code.devices.simlock.hosts can't be named "local": that's t3code's own.'';
        }
      ];
      environment.etc."t3code/policy.json".source = policyFile;
    })

    # Same layout upstream's installer leaves: <home>/tools/<name>/<version>.
    # Everything above the version stays a real, user-owned dir: the server
    # takes its maintenance lock in there. Its pruner skips anything that
    # isn't a real directory, so the store links survive. L+ replaces an
    # earlier npm install.
    (lib.mkIf (cfg.policy.enable && cfg.devices.enable) {
      systemd.tmpfiles.settings."10-t3code" = lib.mkMerge (map (home: let
        owned.d = {
          inherit (home) user;
          group = config.users.users.${home.user}.group;
          mode = "0700";
        };
      in
        {
          "${home.path}" = owned;
          "${home.path}/tools" = owned;
        }
        // lib.concatMapAttrs (name: version: {
          "${home.path}/tools/${name}" = owned;
          "${home.path}/tools/${name}/${version}"."L+".argument = "${ours.t3code-device-tools}/${name}/${version}";
        })
        ours.t3code-device-tools.versions)
      cfg.policy.homes);
    })

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = lib.all (d: lib.elem d knownDrivers) declaredDrivers;
          message = "services.t3code.{providers,customModels}: unknown driver kinds ${toString (lib.subtractLists knownDrivers declaredDrivers)}; known: ${toString knownDrivers}.";
        }
        {
          assertion = lib.all (idName.check) (lib.attrNames cfg.projects ++ lib.attrNames cfg.scheduledTasks);
          message = "services.t3code.{projects,scheduledTasks} names must match [A-Za-z0-9_-]+: they become ids.";
        }
        {
          assertion = lib.all (t: t.schedule ? interval -> t.schedule.interval.minutes >= 1) (lib.attrValues cfg.scheduledTasks);
          message = "services.t3code.scheduledTasks: intervals are at least a minute.";
        }
      ];

      users.users.${cfg.user}.linger = true;

      # Owned from the system side, after local-fs.target, so a dataDir on a
      # bind mount (whose source the mount makes root-owned) lands on the
      # mounted inode and stays writable for the user unit.
      systemd.tmpfiles.settings."10-t3code".${cfg.dataDir}.d = {
        inherit (cfg) user;
        group = config.users.users.${cfg.user}.group;
        mode = "0700";
      };

      networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [cfg.port];

      # `t3` on the system PATH, for `t3 pair` over ssh without the user's
      # shell dotfiles.
      environment.systemPackages = [cfg.package];

      systemd.user.services.t3code = {
        description = "T3 Code server";
        wantedBy = ["default.target"];
        unitConfig.ConditionUser = cfg.user;
        environment =
          {
            NODE_ENV = "production";
            T3CODE_HOME = cfg.dataDir;
            PATH = lib.mkForce (lib.concatStringsSep ":" cfg.path);
          }
          // cfg.environment;
        serviceConfig = {
          ExecStartPre = cfg.preStart ++ [(lib.getExe seedSettings)];
          ExecStart = serve;
          WorkingDirectory = "/home/${cfg.user}";
          Restart = "on-failure";
          RestartSec = 5;
          # Agent tool calls run as children of the server, in its cgroup.
          # The default OOMPolicy=stop would let one greedy child take the
          # server and every other live agent down with it.
          OOMPolicy = "continue";
          KillMode = "mixed";
          TimeoutStopSec = 15;
        };
      };

      # Always present, even with nothing declared, so dropping the last
      # declaration still removes what it made.
      systemd.user.services.t3code-declare = {
        description = "Apply declared T3 Code projects and scheduled tasks";
        wantedBy = ["t3code.service"];
        after = ["t3code.service"];
        requires = ["t3code.service"];
        partOf = ["t3code.service"];
        unitConfig.ConditionUser = cfg.user;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${lib.getExe ours.t3code-declare} ${declareSpec}";
          Restart = "on-failure";
          RestartSec = 10;
        };
      };
    })
  ];
}
