# T3 Code as a NixOS service, configured from Nix as far as upstream allows:
#  - the server, as a `systemd --user` unit of a real login user, so the
#    agents it spawns inherit that user's environment (git, ssh, agent CLIs)
#  - settings.json: `settings` and `secretSettings` are merged in on every
#    start, everything else in the file stays UI-owned
#  - /etc/t3code/policy.json, upstream's managed policy: defaults and locks
#    for every T3 Code on the host, the desktop app's included, checked by
#    this build's own `t3 policy check` so a bad policy fails the build
#  - the Device panel's npm tools, linked in from the store
#  - dictation's speech models, pinned from upstream's catalog and linked in
#    from the store instead of downloaded by the UI
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
  # A real extend, not `overlay pkgs pkgs`: the overlay's packages refer to
  # each other (t3code-device-tools is t3code.deviceTools), and on a host
  # that doesn't apply the overlay, callPackage would otherwise hand them
  # nixpkgs' t3code.
  ours = pkgs.extend self.overlays.default;
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
    simlockDeviceHosts =
      lib.mapAttrsToList (id: h: {
        kind = "simlock";
        inherit id;
        inherit (h) label gatewayUrl maxLeases maxLeaseMinutes;
      })
      simlockHosts;
  };
  simlockSecrets =
    lib.listToAttrs (lib.imap0 (i: h: lib.nameValuePair "simlockDeviceHosts.${toString i}.agentToken" h.agentTokenFile)
      (lib.attrValues simlockHosts));

  speechCatalog = cfg.package.speech or ours.t3code.speech;
  speechModels = lib.optionals (cfg.speech.model != null) (map (id: speechCatalog.models.${id}) (lib.unique ([cfg.speech.model] ++ cfg.speech.extraModels)));
  speechSettings = lib.optionalAttrs (cfg.speech.model != null) {speechModelId = cfg.speech.model;};

  declaredSettings = json.generate "t3code-settings.json" (lib.foldl' lib.recursiveUpdate {} [providerSettings simlockSettings speechSettings cfg.settings]);
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
    projects =
      lib.mapAttrs (_: p: {
        inherit (p) workspaceRoot title createWorkspaceRootIfMissing settings;
      })
      cfg.projects;
    scheduledTasks =
      lib.mapAttrs (_: t: {
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
      })
      cfg.scheduledTasks;
  };

  # Links are server-side state (peer_environment_links + a token in the
  # secret store), made by `t3 environment link`, which works whether or not
  # the server runs. A link is a 30-day MCP session on the peer, and every
  # link registers one more client in the peer's Connections, so a peer is
  # only relinked when it isn't linked yet, its link is expiring, or its
  # declared access changed. Peers a link lists none of the declared
  # addresses for (UI-made links, dropped peers) are left alone.
  #
  # A peer that's off doesn't fail the unit, so `systemctl --failed` stays
  # about real refusals (pairing code, version, storage); the timer retries it.
  #
  # The pairing code goes on t3's command line (it takes no file or env var),
  # so other users of the host can see it in /proc while a link runs.
  peers = cfg.linkedEnvironments.peers;
  renewSeconds = 7 * 24 * 3600;
  linkPeers = pkgs.writeShellApplication {
    name = "t3code-link-peers";
    runtimeInputs = [pkgs.coreutils pkgs.jq cfg.package];
    text =
      ''
        base=${lib.escapeShellArg cfg.dataDir}
        listed=$(t3 environment list --json --base-dir "$base")
        cutoff=$(( $(date +%s) + ${toString renewSeconds} ))
        failed=0
      ''
      + lib.concatStrings (lib.mapAttrsToList (name: p: ''
          if jq -e --argjson urls ${lib.escapeShellArg (builtins.toJSON p.urls)} \
              --arg access ${lib.escapeShellArg p.access} --argjson cutoff "$cutoff" '
                any(.[]; (.urls | any(. as $u | $urls | index($u)))
                  and .access == $access and .status != "expired"
                  and (.expiresAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) > $cutoff)
              ' <<<"$listed" >/dev/null; then
            echo ${lib.escapeShellArg "${name}: linked"}
          elif ! test -s ${lib.escapeShellArg p.pairingCodeFile}; then
            echo ${lib.escapeShellArg "${name}: ${p.pairingCodeFile} is missing or empty"}
            failed=1
          elif out=$(t3 environment link --base-dir "$base" \
              ${lib.escapeShellArgs ([(lib.head p.urls)] ++ lib.concatMap (u: ["--url" u]) (lib.tail p.urls))} \
              --access ${lib.escapeShellArg p.access} \
              --pairing-code "$(tr -d '\n' < ${lib.escapeShellArg p.pairingCodeFile})" 2>&1); then
            printf '%s\n' "$out" | grep -F 'Linked ' || true
          elif printf '%s\n' "$out" | grep -qE 'answered as a T3 Code environment|stopped answering while linking|could not reach'; then
            echo ${lib.escapeShellArg "${name}: not answering, retrying on the next run"}
          else
            printf '%s\n' "$out"
            echo ${lib.escapeShellArg "${name}: link refused"}
            failed=1
          fi
        '')
        peers)
      + ''
        exit "$failed"
      '';
  };
  # What `peerOrigin` upstream will send credentials to: https, or plain
  # http only to loopback or a tailnet name. Upstream stores the origin, and
  # an origin is what the up-to-date check compares against.
  peerUrl = lib.types.strMatching "(https://[^/]+|http://(localhost|127[.][0-9.]+|[[]::1[]]|[^/]+[.]ts[.]net)(:[0-9]+)?)";

  # trustTailnet: caddy presents the shared secret as a bearer token on behalf
  # of tailnet clients. Upstream already verifies that secret as a session with
  # the scopes a paired client gets (SessionStore's reusable dev session), so
  # this needs no patch to the auth code. caddy's {file.*} placeholder keeps the
  # trailing newline, which Go then refuses as a header value (502), so caddy
  # reads a newline-free copy. A missing copy injects "Bearer ", which t3code
  # treats as no credential: it fails closed, not open.
  tn = cfg.trustTailnet;
  tailnetTokenDir = "/run/t3code-tailnet";
  tailnetToken = "${tailnetTokenDir}/token";
  upstreamHost =
    if lib.elem cfg.host ["0.0.0.0" "::" ""]
    then "127.0.0.1"
    else cfg.host;

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

    speech = {
      model = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum (lib.attrNames speechCatalog.models));
        default = null;
        example = "handy-computer/parakeet-unified-en-0.6b-gguf";
        description = ''
          Catalog id of the dictation model this environment transcribes with.
          It's fetched into the store, linked into the server's model folder
          with Silero VAD, and selected (`speechModelId`). Null leaves models
          to the UI, which downloads them into the data dir.
        '';
      };
      extraModels = lib.mkOption {
        type = lib.types.listOf (lib.types.enum (lib.attrNames speechCatalog.models));
        default = [];
        description = "More catalog models to link in, so switching in the UI needs no download.";
      };
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

    linkedEnvironments = {
      enable = lib.mkEnableOption ''
        linked environments (beta): agents here launch and drive threads on
        other T3 Code machines. Locked on in the policy, so the desktop app
        on this host gets it too
      '';
      peers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            urls = lib.mkOption {
              type = lib.types.nonEmptyListOf peerUrl;
              example = ["https://t3.example.com"];
              description = ''
                Origins (no path or trailing slash) the peer answers at, tried
                in order. https, or plain http only to loopback or a tailnet
                name: upstream won't send the link's credentials elsewhere.
              '';
            };
            pairingCodeFile = lib.mkOption {
              type = lib.types.str;
              description = ''
                File holding a pairing code the peer accepts every time: its
                `sharedSecretFile`. A one-time `t3 pair` code is gone after the
                first link, and links expire after 30 days.
              '';
            };
            access = lib.mkOption {
              type = lib.types.enum ["read-only" "approval-required" "auto-accept-edits" "auto" "full-access"];
              default = "approval-required";
              description = "What this environment's agents may do on the peer. Changing it relinks.";
            };
          };
        });
        default = {};
        description = ''
          Other T3 Code environments to link this server to. Checked at every
          server start and hourly; a peer is linked when it isn't yet, or its
          link expires within a week. Dropping a peer doesn't unlink it:
          `t3 environment unlink <id>`.
        '';
      };
    };

    trustTailnet = {
      enable = lib.mkEnableOption ''
        a caddy site in front of the server where a client connecting from
        the tailnet is signed in without pairing. caddy adds
        `Authorization: Bearer <sharedSecretFile>` to tailnet requests that
        carry no Authorization of their own, which upstream accepts as a
        session with a paired client's scopes. Everyone else still pairs.
        Linked peers still link with the pairing code: the link is what
        carries their access level
      '';
      virtualHost = lib.mkOption {
        type = lib.types.str;
        example = "saturn.ts.example.com";
        description = ''
          caddy site address (`services.caddy.virtualHosts` key). TLS is the
          host's business: add a cert through the same virtualHost
          (`useACMEHost`, or a `tls` block in its extraConfig).
        '';
      };
      ranges = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.str;
        # Tailscale's (and headscale's default) node prefixes.
        default = ["100.64.0.0/10" "fd7a:115c:a1e0::/48"];
        description = ''
          Client addresses that count as the tailnet, matched with caddy's
          `client_ip`. That is the TCP peer unless caddy's `trusted_proxies`
          says otherwise, so a proxy that relays the public internet to this
          site over the tailnet must be listed in `trusted_proxies`, or its
          visitors arrive with its tailnet address and are trusted.
        '';
      };
      excludeRanges = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["100.64.0.3/32"];
        description = ''
          Addresses inside `ranges` that are not trusted. Put this host's own
          tailnet address here on a machine where other local users exist:
          a process on the host that dials the tailnet name connects from it.
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
      assertions = [
        {
          assertion = peers != {} -> cfg.enable && cfg.linkedEnvironments.enable;
          message = "services.t3code.linkedEnvironments.peers needs services.t3code.enable and linkedEnvironments.enable: the server holds the links, and upstream refuses to link with the feature off.";
        }
      ];
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
          (lib.mkIf cfg.linkedEnvironments.enable {linkedEnvironmentsEnabled = lock true;})
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
        {
          assertion = cfg.speech.extraModels != [] -> cfg.speech.model != null;
          message = "services.t3code.speech.extraModels needs speech.model: with no model declared, models are the UI's.";
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

      # Where the server's model store looks. It follows the links (stat, not
      # lstat), hashes each file once against the catalog digest and records
      # that in a .verified file beside it, so the folder stays user-owned.
      # L+ replaces a copy the UI downloaded earlier.
      systemd.tmpfiles.settings."10-t3code-speech" = lib.mkIf (speechModels != []) (let
        owned.d = {
          inherit (cfg) user;
          group = config.users.users.${cfg.user}.group;
          mode = "0700";
        };
        modelDir = "${stateDir}/speech/models";
      in
        {
          ${stateDir} = owned;
          "${stateDir}/speech" = owned;
          ${modelDir} = owned;
        }
        // lib.listToAttrs (map (m: lib.nameValuePair "${modelDir}/${m.filename}" {"L+".argument = "${m}";}) (speechModels ++ [speechCatalog.vad])));

      networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [cfg.port];

      # Peers come and go (laptops, desktops off at night), so a failed link
      # is retried by the timer rather than by Restart=.
      systemd.user.services.t3code-link-peers = lib.mkIf (peers != {}) {
        description = "Link the declared T3 Code peer environments";
        wantedBy = ["t3code.service"];
        after = ["t3code.service"];
        unitConfig.ConditionUser = cfg.user;
        environment.T3CODE_HOME = cfg.dataDir;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe linkPeers;
        };
      };
      systemd.user.timers.t3code-link-peers = lib.mkIf (peers != {}) {
        description = "Keep the declared T3 Code peer links current";
        wantedBy = ["timers.target"];
        unitConfig.ConditionUser = cfg.user;
        timerConfig = {
          OnActiveSec = "5min";
          OnUnitActiveSec = "1h";
        };
      };

      # `t3` on the system PATH, for `t3 pair` over ssh without the user's
      # shell dotfiles.
      environment.systemPackages = [cfg.package];

      systemd.user.services.t3code = {
        description = "T3 Code server";
        wantedBy = ["default.target"];
        unitConfig = {
          ConditionUser = cfg.user;
          # Never give up. A deploy's activation restarts the unit itself, and
          # those restarts count toward the start limit too: a pre-start that
          # fails three times in a second (secrets not rendered yet) left the
          # server dead until someone ran reset-failed, and a user unit doesn't
          # show in `systemctl --failed`. Restart= then retries every 5 s.
          StartLimitIntervalSec = 0;
        };
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

    (lib.mkIf tn.enable {
      assertions = [
        {
          assertion = cfg.enable && cfg.sharedSecretFile != null;
          message = "services.t3code.trustTailnet needs services.t3code.enable and sharedSecretFile: the secret is the credential caddy presents for tailnet clients.";
        }
      ];

      services.caddy.enable = true;
      services.caddy.virtualHosts.${tn.virtualHost}.extraConfig = ''
        @t3codeTailnet {
          client_ip ${lib.concatStringsSep " " tn.ranges}
          ${lib.optionalString (tn.excludeRanges != []) "not client_ip ${lib.concatStringsSep " " tn.excludeRanges}"}
          # A client's own credential (a paired cookie aside) wins.
          not header Authorization *
          # /mcp only takes MCP client tokens; injecting would turn its
          # "no credential, go sign in" 401 into an invalid-credential one.
          not path /mcp /mcp/*
        }
        request_header @t3codeTailnet Authorization "Bearer {file.${tailnetToken}}"
        reverse_proxy ${upstreamHost}:${toString cfg.port}
      '';

      # Re-run whenever the secret changes; caddy reads the copy per request,
      # so a rotated secret needs no caddy restart.
      systemd.services.t3code-tailnet-token = {
        description = "Newline-free copy of the T3 Code shared secret for caddy";
        # multi-user too: a deploy only reloads caddy, which starts nothing it
        # wants, and the path unit below fires on changes, not on first boot.
        wantedBy = ["caddy.service" "multi-user.target"];
        before = ["caddy.service"];
        serviceConfig = {
          Type = "oneshot";
          Group = config.services.caddy.group;
          RuntimeDirectory = baseNameOf tailnetTokenDir;
          RuntimeDirectoryMode = "0750";
          RuntimeDirectoryPreserve = true;
          UMask = "0227";
        };
        # Never fails: a secret not rendered yet must not take caddy (and
        # every other site on the host) down with it.
        script = ''
          if [ -s ${lib.escapeShellArg cfg.sharedSecretFile} ]; then
            tr -d '\n' < ${lib.escapeShellArg cfg.sharedSecretFile} > ${tailnetToken}.new
            mv ${tailnetToken}.new ${tailnetToken}
          else
            rm -f ${tailnetToken}
          fi
        '';
      };
      systemd.paths.t3code-tailnet-token = {
        wantedBy = ["multi-user.target"];
        pathConfig.PathChanged = cfg.sharedSecretFile;
      };
    })
  ];
}
