# Simlock (packages/simlock) as system services: the worker that owns the
# Android emulators, and the gateway that puts several workers behind one URL
# (what services.t3code.devices.simlock.hosts points at). Upstream's own setup
# is a `systemd --user` unit that `simlock daemon install` writes, frozen to
# whatever store paths it saw that day, and no unit at all for the gateway;
# here both are system units running the daemon in the foreground as
# `simlock`, sharing SIMLOCK_HOME (the gateway keeps to its gateway/ folder).
#  - config.json is rendered from `settings` on every start, secrets read
#    from files, so a `simlock config set` lasts until the next restart
#  - the worker's Android SDK is a read-only store path (androidenv) with its
#    system images built in, so downloads are off: Simlock would otherwise
#    try to sdkmanager-install into it
#  - the gateway's tokens can be declared. Simlock keeps a token as the
#    sha256 of its secret in state.db, so declaring one is upserting that row
#    after every start; declared rows are `tok_nix_<name>`, and the ones no
#    longer declared are deleted. Tokens made with the CLI are left alone.
#
# Linux workers are Android-only, and need KVM.
self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.simlock;
  ours = pkgs.extend self.overlays.default;
  json = pkgs.formats.json {};
  home = "/var/lib/simlock";
  gatewayDir = "${home}/gateway";
  daemon = lib.getExe' cfg.package "simlock-daemon";

  # Every module simlock ships that T3 Code's Device panel needs: agent-device
  # for driving a lease, stream and input for showing it. Each has to be on at
  # both ends.
  sharedCapabilities = {
    agent-device.enabled = true;
    stream.enabled = true;
    input.enabled = true;
  };

  sqlString = s: "'${lib.replaceStrings ["'"] ["''"] s}'";

  # rtrimstr would leave a second trailing newline; the token seeding reads
  # the files through $(...), which drops them all.
  readSecret = ''(. | sub("\n+$"; ""))'';

  defaultSdk =
    ((pkgs.androidenv.override {licenseAccepted = cfg.worker.android.acceptLicense;}).composeAndroidPackages {
      includeEmulator = true;
      includeSystemImages = true;
      platformVersions = map toString cfg.worker.android.apiLevels;
      systemImageTypes = ["google_apis"];
      abiVersions = [cfg.worker.android.abi];
    }).androidsdk;

  worker = cfg.worker;
  workerSettings = json.generate "simlock-worker.json" (lib.recursiveUpdate {
      android.emulator = {
        headless = true;
        # No display and nothing to render on; "auto" picks host GPU paths
        # that need one.
        gpu = "swiftshader_indirect";
      };
      downloads.policy = "never";
      # It can only update an `npm i -g` install.
      update.check = false;
      capabilities = lib.recursiveUpdate sharedCapabilities {
        agent-device.command = worker.agentDevice;
      };
      gateway = lib.optionalAttrs (worker.gateway != null) {
        inherit (worker.gateway) url label;
      };
    }
    worker.settings);

  renderWorkerConfig = pkgs.writeShellScript "simlock-worker-config" ''
    set -eu
    umask 077
    ${
      if worker.gateway == null
      then "cp ${workerSettings} ${home}/config.json.new"
      else ''
        ${lib.getExe pkgs.jq} --rawfile t "$CREDENTIALS_DIRECTORY/gateway-token" \
          '.gateway.token = ($t | ${readSecret})' ${workerSettings} > ${home}/config.json.new
      ''
    }
    mv ${home}/config.json.new ${home}/config.json
  '';

  gateway = cfg.gateway;
  gatewaySettings = json.generate "simlock-gateway.json" (lib.recursiveUpdate {
      http = {inherit (gateway) host port;};
      update.check = false;
      capabilities = sharedCapabilities;
    }
    gateway.settings);

  renderGatewayConfig = pkgs.writeShellScript "simlock-gateway-config" ''
    set -eu
    umask 077
    install -d -m700 ${gatewayDir}
    cp ${gatewaySettings} ${gatewayDir}/config.json.new
    mv ${gatewayDir}/config.json.new ${gatewayDir}/config.json
  '';

  # After the daemon is up, so state.db exists and is migrated. A token whose
  # secret changed is unpinned from its worker: rotating a worker's token is
  # how it gets back in after its state was wiped.
  seedTokens = pkgs.writeShellScript "simlock-gateway-tokens" ''
    set -eu
    for _ in $(seq 120); do
      ${lib.getExe pkgs.curl} -fsS -o /dev/null http://${gateway.host}:${toString gateway.port}/v1/healthz && break
      sleep 0.5
    done
    now=$(($(date +%s) * 1000))
    hash() { printf %s "$(cat "$CREDENTIALS_DIRECTORY/token-$1")" | sha256sum | cut -d' ' -f1; }
    {
      echo "BEGIN;"
      echo "DELETE FROM tokens WHERE id LIKE 'tok\_nix\_%' ESCAPE '\\' AND id NOT IN (${lib.concatMapStringsSep ", " (n: sqlString "tok_nix_${n}") (lib.attrNames gateway.tokens ++ [""])});"
      ${lib.concatStrings (lib.mapAttrsToList (name: t: ''
        echo "INSERT INTO tokens (id, hash, role, label, created_at) VALUES (${sqlString "tok_nix_${name}"}, '$(hash ${name})', ${sqlString t.role}, ${sqlString t.label}, $now) ON CONFLICT(id) DO UPDATE SET hash = excluded.hash, role = excluded.role, label = excluded.label, worker_id = CASE WHEN tokens.hash = excluded.hash THEN tokens.worker_id ELSE NULL END;"
      '')
      gateway.tokens)}
      echo "COMMIT;"
    } | ${lib.getExe pkgs.sqlite} -bail -cmd '.timeout 10000' ${gatewayDir}/state.db
  '';

  common = {
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = ["network-online.target"];
    environment = {
      SIMLOCK_HOME = home;
      HOME = home;
    };
    serviceConfig = {
      User = "simlock";
      Group = "simlock";
      StateDirectory = "simlock";
      StateDirectoryMode = "0700";
      Restart = "on-failure";
      RestartSec = 10;
      # The daemon stops its own children (emulators, adb) on SIGTERM, which
      # can take a while; anything left after it exits gets killed.
      KillMode = "mixed";
      TimeoutStopSec = 300;
    };
  };
in {
  options.services.simlock = {
    package = lib.mkPackageOption ours "simlock" {};

    worker = {
      enable = lib.mkEnableOption "a Simlock worker leasing out Android emulators";

      gateway = lib.mkOption {
        default = null;
        description = "The gateway this worker joins. null runs it standalone, with its own API on 127.0.0.1:4701.";
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            url = lib.mkOption {
              type = lib.types.strMatching "wss?://[^[:space:]]+";
              example = "wss://gateway.example.ts.net:4700";
            };
            tokenFile = lib.mkOption {
              type = lib.types.str;
              description = "File holding this worker's join token (a `worker` token on the gateway). The first worker to join with it is the only one it ever lets in.";
            };
            label = lib.mkOption {
              type = lib.types.str;
              default = config.networking.hostName;
              defaultText = lib.literalExpression "config.networking.hostName";
            };
          };
        });
      };

      android = {
        acceptLicense = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Accept the Android SDK license, which the default SDK won't build without.";
        };
        apiLevels = lib.mkOption {
          type = lib.types.listOf lib.types.ints.positive;
          default = [35];
          description = "Android versions with a google_apis system image in the default SDK. Leases ask for one of these.";
        };
        abi = lib.mkOption {
          type = lib.types.enum ["x86_64" "arm64-v8a"];
          default =
            if pkgs.stdenv.hostPlatform.isAarch64
            then "arm64-v8a"
            else "x86_64";
          defaultText = lib.literalExpression ''"x86_64" or "arm64-v8a", after the host'';
        };
        sdk = lib.mkOption {
          type = lib.types.package;
          default = defaultSdk;
          defaultText = lib.literalExpression "androidenv's composeAndroidPackages with the emulator and `apiLevels`' images";
          description = "An androidenv androidsdk: Simlock wants its cmdline-tools, emulator and platform-tools, under libexec/android-sdk.";
        };
      };

      agentDevice = lib.mkOption {
        type = lib.types.str;
        default = let
          version = ours.t3code-device-tools.versions.agent-device;
        in "${ours.t3code-device-tools}/agent-device/${version}/node_modules/.bin/agent-device";
        defaultText = lib.literalExpression "t3code-device-tools' agent-device";
        description = "The agent-device CLI. Its version has to match the @agent-device/proxy simlock pins.";
      };

      settings = lib.mkOption {
        type = json.type;
        default = {};
        description = "Merged over this module's config.json for the worker (incubator.callstack.com/simlock/docs/reference/configuration).";
      };
    };

    gateway = {
      enable = lib.mkEnableOption "a Simlock gateway in front of several workers";
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Simlock does no TLS: keep it on loopback behind a proxy that passes WebSocket upgrades and doesn't buffer (caddy: `flush_interval -1`).";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 4700;
      };
      tokens = lib.mkOption {
        default = {};
        description = "Tokens the gateway takes, declared. Its CLI-made ones keep working alongside.";
        type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
          options = {
            role = lib.mkOption {
              type = lib.types.enum ["agent" "operator" "worker"];
              description = "agent: leases devices (T3 Code). worker: joins as one. operator: runs the fleet.";
            };
            secretFile = lib.mkOption {
              type = lib.types.str;
              description = "File holding the token's secret, readable by root.";
            };
            label = lib.mkOption {
              type = lib.types.str;
              default = name;
            };
          };
        }));
      };
      settings = lib.mkOption {
        type = json.type;
        default = {};
        description = "Merged over this module's config.json for the gateway.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (worker.enable || gateway.enable) {
      users.users.simlock = {
        isSystemUser = true;
        group = "simlock";
        inherit home;
      };
      users.groups.simlock = {};

      # `sudo -u simlock simlock status` and the like, against the right home.
      environment.systemPackages = [
        (pkgs.writeShellScriptBin "simlock" ''
          export SIMLOCK_HOME=${home}
          exec ${lib.getExe cfg.package} "$@"
        '')
      ];
    })

    (lib.mkIf worker.enable {
      warnings = lib.optional (!(lib.hasInfix "/${cfg.package.agentDeviceVersion}/" worker.agentDevice)) ''
        services.simlock.worker.agentDevice isn't agent-device ${cfg.package.agentDeviceVersion}, the version simlock ${cfg.package.version} pins; leases may fail to open.
      '';

      systemd.services.simlock-worker = lib.recursiveUpdate common {
        description = "Simlock worker";
        environment = {
          ANDROID_HOME = "${worker.android.sdk}/libexec/android-sdk";
          ANDROID_SDK_ROOT = "${worker.android.sdk}/libexec/android-sdk";
          ANDROID_USER_HOME = "${home}/.android";
          JAVA_HOME = pkgs.jdk17_headless.home;
        };
        # agent-device's own children (adb) are found on PATH.
        path = [pkgs.jdk17_headless];
        serviceConfig = {
          SupplementaryGroups = ["kvm"];
          ExecStartPre = renderWorkerConfig;
          ExecStart = daemon;
          LoadCredential = lib.optional (worker.gateway != null) "gateway-token:${worker.gateway.tokenFile}";
        };
      };
    })

    (lib.mkIf gateway.enable {
      assertions = [
        {
          # They go into SQL and credential names.
          assertion = lib.all (n: builtins.match "[a-z0-9-]+" n != null) (lib.attrNames gateway.tokens);
          message = "services.simlock.gateway.tokens names must match [a-z0-9-]+.";
        }
      ];
      systemd.services.simlock-gateway = lib.recursiveUpdate common {
        description = "Simlock gateway";
        serviceConfig = {
          ExecStartPre = renderGatewayConfig;
          ExecStart = "${daemon} --gateway";
          ExecStartPost = seedTokens;
          LoadCredential = lib.mapAttrsToList (name: t: "token-${name}:${t.secretFile}") gateway.tokens;
        };
      };
    })
  ];
}
