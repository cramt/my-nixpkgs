# my-nixpkgs

Packages that nixpkgs doesn't have, or has too old, for `x86_64-linux` and
`aarch64-linux`, plus a few for `aarch64-darwin`. CI keeps them current and
pushes builds to [cramt.cachix.org](https://cramt.cachix.org).

| Package | What it is |
|---|---|
| `_1password-cli` | 1Password's `op`, tracking upstream, plus the armv7l build nixpkgs leaves out (shadows nixpkgs') |
| `agent-browser` | Vercel's browser-automation CLI for AI agents |
| `agentsview` | Local session analytics for coding agents |
| `batt` | Battery charge limiter daemon for Apple Silicon MacBooks (aarch64-darwin only) |
| `caddy-cloudflare` | Caddy with the Cloudflare DNS provider, for ACME DNS-01 on names nothing public can reach |
| `cli-proxy-api-panel` | CLIProxyAPI's web management panel |
| `cockatrice` | Virtual tabletop for card games, tracking stable releases |
| `colibri` | Streaming inference engine for MoE models (CPU by default, `rocmSupport`/`vulkanSupport` overrides) |
| `cpa-prometheus` | CLIProxyAPI plugin exporting Prometheus metrics |
| `fluxer` | Fluxer chat desktop app, from the upstream AppImage (x86_64) |
| `microg-re` | Morphe's microG (`app.revanced.android.gms`): Google sign-in for the patched YouTube and Music APKs |
| `revanced-magisk-module` | j-hc's CI builds: YouTube, Music, Reddit (Morphe), Twitter (Piko), Google Photos (De-Vanced) as APKs and Magisk modules, per app in `passthru.apps` |
| `posthog-cli` | PostHog's CLI (source map upload etc.), from upstream's static musl builds |
| `rhystic-tracker` | MTG Arena match tracker |
| `simlock` | Leases simulators, emulators and phones to coding agents (worker + gateway; `nixosModules.simlock` runs them) |
| `steamlink` | Valve Steam Link client, aarch64 only |
| `t3code`, `t3code-desktop`, `t3code-device-tools` | T3 Code server/CLI, desktop app, and the Device panel's npm tools, from upstream nightlies |
| `t3code-declare` | Applies declared projects and scheduled tasks to a running T3 Code server (used by `nixosModules.t3code`) |
| `terraform-provider-better-uptime`, `terraform-provider-mimir`, `terraform-provider-posthog` | OpenTofu/Terraform providers nixpkgs doesn't package, built with its `mkProvider` so `opentofu.withPlugins` takes them |
| `zed-delta` | Zed's Delta agent (not git-delta, so not `delta`) |

`zed-delta`, `steamlink`, `_1password-cli` and `revanced-magisk-module` are unfree. Delta's license is Zed's
[terms](https://zed.dev/terms) plus Delta's
[Early Access Agreement](https://delta.dev/early-access); the build downloads
the release from delta.dev, nothing is redistributed here.

## Usage

```nix
{
  inputs.my-nixpkgs = {
    url = "github:cramt/my-nixpkgs";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # NixOS or Home Manager:
  nixpkgs.overlays = [ inputs.my-nixpkgs.overlays.default ];
}
```

The overlay builds against your nixpkgs, so with `follows` the store paths
only match the cache when your nixpkgs pin matches this repo's. Or run one
straight from here: `nix run github:cramt/my-nixpkgs#t3code`.

## NixOS module: `nixosModules.t3code`

Runs the T3 Code server as a `systemd --user` unit of a login user, configured
from Nix as far as upstream allows:

```nix
{
  imports = [ inputs.my-nixpkgs.nixosModules.t3code ];
  services.t3code = {
    enable = true;
    user = "alice";
    openFirewall = true;
    sharedSecretFile = "/run/secrets/t3code";   # fixed pairing secret
    providers.codex = false;
    settings.continueThreadsAfterServerUpdate = true;
    speech.model = "handy-computer/parakeet-unified-en-0.6b-gguf";
    policy.settings.defaultRuntimeMode = { value = "auto-accept-edits"; locked = false; };
    projects.website.workspaceRoot = "/home/alice/website";
    scheduledTasks.standup = {
      project = "/home/alice/website";
      prompt = "Summarise yesterday's commits.";
      schedule.daily = { timeOfDay = "09:00"; weekdays = [ 1 2 3 4 5 ]; };
      model.model = "claude-sonnet-5-5";
    };
  };
}
```

- `settings` and `secretSettings` (dot path to a file) are merged into
  settings.json on every start. The rest of the file stays the UI's.
- `policy` writes `/etc/t3code/policy.json`, upstream's managed policy, and
  checks it with `t3 policy check` at build time.
- `speech.model` (plus `speech.extraModels`) pins dictation models from
  upstream's catalog: they're fetched into the store, linked into the
  server's model folder with Silero VAD, and the first is selected. The
  other server-side voice settings (`speechAcceleration`,
  `speechModelUnloadTimeout`, `speechProjectCustomWords`) are plain
  `settings`. Microphone, language and the per-device vocabulary are client
  settings and stay in each client.
- `projects` and `scheduledTasks` are applied by `t3code-declare` after every
  start. Nix owns only what it declares: anything made in the UI is left
  alone. A folder you already registered is taken over in place. Dropping a
  declaration deletes what it created (a project with threads is archived).
  It waits out a server that's still starting, a long database migration
  included, without holding up a NixOS switch.
- `schedule.webhook = {}` runs a task on every request to its URL. The server
  mints the token, so the URL exists only once the task is applied:
  `t3code-declare` writes it (0600) to the task's read-only `webhookUrlFile`,
  and a local caller POSTs to `$(cat webhookUrlFile)`.
- `linkedEnvironments.enable` locks the beta on in the policy, and
  `linkedEnvironments.peers` links this server to other T3 Code machines with
  a pairing code file (the peer's `sharedSecretFile`). A user timer links a
  peer that isn't linked yet and relinks one whose 30-day link expires within
  a week. A peer that's off is retried on the next run, not a failed unit.
  Peer URLs must be https, or loopback/tailnet http: upstream won't
  send the credentials anywhere else.

- `trustTailnet` puts a caddy site (`virtualHost`) in front of the server
  where clients connecting from the tailnet (`ranges`, minus `excludeRanges`)
  are signed in without pairing: caddy adds the `sharedSecretFile` as a
  bearer token to their requests, and upstream accepts that as a session with
  a paired client's scopes. No patch to t3code's auth. Everyone else still
  pairs, and linked peers still link with the pairing code. TLS for the site
  is left to the host. A proxy relaying the public internet to the site over
  the tailnet must be in caddy's `trusted_proxies`, or its visitors count as
  tailnet.

`nix build .#checks.x86_64-linux.t3code-module` evaluates a sample host that
uses every option, and runs `caddy validate` on the site trustTailnet makes.

## NixOS module: `nixosModules.simlock`

Simlock's worker and gateway as system services, for leasing Android
emulators to agents (T3 Code's `devices.simlock.hosts` points at the
gateway). Upstream's own setup is a `systemd --user` unit frozen to the store
paths it saw at install time; this runs `simlock-daemon` in the foreground as
the `simlock` user instead, with `SIMLOCK_HOME=/var/lib/simlock`.

```nix
services.simlock = {
  worker = {
    enable = true;
    android.acceptLicense = true; # the default SDK won't build without it
    gateway = {
      url = "wss://gateway.example.ts.net:4700";
      tokenFile = "/run/secrets/simlock-worker";
    };
  };
  gateway = {
    enable = true;
    tokens.box = { role = "worker"; secretFile = "/run/secrets/simlock-worker"; };
    tokens.t3 = { role = "agent"; secretFile = "/run/secrets/simlock-agent"; };
  };
};
```

- `config.json` is rendered from `settings` on every start, secrets read from
  files, so a `simlock config set` lasts until the next restart.
- The worker's Android SDK is a read-only androidenv store path with the
  `apiLevels`' google_apis images built in, so downloads are off. Emulators
  run headless on swiftshader, and need KVM. The SDK is unfree: allow it.
- Gateway tokens are declared. Simlock keeps a token as the sha256 of its
  secret in `state.db`, so each start upserts `tok_nix_<name>` rows and deletes
  the ones no longer declared. Changing a worker token's secret unpins it, which
  is how a worker whose state was wiped gets back in. CLI-made tokens are kept.
- agent-device, stream and input are on at both ends: they're what T3 Code's
  Device panel drives a lease with.
- `sudo -u simlock simlock status` (or `--gateway worker list`) for a look.

`nix build .#checks.x86_64-linux.simlock-module` boots a gateway and a worker in
a VM and checks the declared tokens: the worker joins with its own, an agent
token reads back as an agent, and one that's no longer declared stops working.

## Adding a package

Drop `packages/<name>/default.nix` in. That makes it `pkgs.<name>` in the
overlay and `packages.<system>.<name>` in the flake, on every system its
`meta.platforms` allows. A folder named after a nixpkgs attribute shadows it.

Darwin is opt-in. A package only shows up under `aarch64-darwin` (and gets
built on the macOS CI leg) if its `meta.platforms` names a darwin system.
Leaving `meta.platforms` unset keeps it Linux-only.

For CI to keep it current, give it an updater:

- `passthru.updateScript = nix-update-script { };` for anything
  [nix-update](https://github.com/Mic92/nix-update) can follow. Pass flags
  through `extraArgs`.
- `packages/<name>/update.sh` for anything it can't. It runs from the repo
  root with `packages/<name>/sources.json` as its argument and must leave the
  tree unchanged when nothing is new.

`nix run .#update` runs every updater, `nix run .#update -- <name>` one.

## How updates land

Every hour `update.yml` runs each updater on its own, keeping one patch per
package that moved. Updaters run on Linux, except for darwin-only packages,
which bump on macOS. Each patch is then built on x86_64-linux, aarch64-linux
and aarch64-darwin against an otherwise clean tree. A bump is committed
(one commit per package) only if it built on at least one of them and failed
on neither. The rest wait for a later run, so one broken upstream release
doesn't block the others.
