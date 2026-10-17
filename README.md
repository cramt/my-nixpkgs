# my-nixpkgs

Packages that nixpkgs doesn't have, or has too old, for `x86_64-linux` and
`aarch64-linux`. CI keeps them current and pushes builds to
[cramt.cachix.org](https://cramt.cachix.org).

| Package | What it is |
|---|---|
| `agent-browser` | Vercel's browser-automation CLI for AI agents |
| `agentsview` | Local session analytics for coding agents |
| `cli-proxy-api-panel` | CLIProxyAPI's web management panel |
| `cockatrice` | Virtual tabletop for card games, tracking stable releases |
| `colibri` | Streaming inference engine for MoE models (CPU by default, `rocmSupport`/`vulkanSupport` overrides) |
| `cpa-prometheus` | CLIProxyAPI plugin exporting Prometheus metrics |
| `rea-agents` | Reverse-engineering CLI and MCP server |
| `rhystic-tracker` | MTG Arena match tracker |
| `steamlink` | Valve Steam Link client, aarch64 only |
| `t3code`, `t3code-desktop` | T3 Code server/CLI and desktop app, from upstream nightlies |
| `zed-delta` | Zed's Delta agent (not git-delta, so not `delta`) |

`zed-delta` and `steamlink` are unfree. Delta's license is Zed's
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

## Adding a package

Drop `packages/<name>/default.nix` in. That makes it `pkgs.<name>` in the
overlay and `packages.<system>.<name>` in the flake, on every system its
`meta.platforms` allows. A folder named after a nixpkgs attribute shadows it.

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
package that moved. Each patch is then built on x86_64 and aarch64 against an
otherwise clean tree. A bump is committed (one commit per package) only if it
built on at least one of them and failed on neither. The rest wait for a
later run, so one broken upstream release doesn't block the others.
