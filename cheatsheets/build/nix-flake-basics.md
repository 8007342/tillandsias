---
tags: [nix, flake, reproducible-builds, dev-shell, direnv]
languages: []
since: 2026-04-25
last_verified: 2026-04-25
sources:
  - https://nix.dev/concepts/flakes
  - https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-flake.html
  - https://github.com/nix-community/nix-direnv
authority: high
status: current
---

# Nix flakes — basics

@trace spec:agent-cheatsheets

## Provenance

- nix.dev — Nix Foundation's official tutorial site, "Flakes" concept page: <https://nix.dev/concepts/flakes>
- Official Nix manual, `nix flake` command reference: <https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-flake.html>
- nix-direnv (community direnv ↔ flakes integration): <https://github.com/nix-community/nix-direnv>
- **Last updated:** 2026-04-25

## Use when

You want **reproducible** development environments — same toolchain versions on every developer's machine and in CI, derived from a single committed file. Per Tillandsias methodology (see `~/src/tillandsias/CLAUDE.md`), new projects scaffolded inside the forge SHOULD use a Nix flake as the build / dev-shell layer.

Nix gives you: hermetic builds (closure of every dep is pinned), atomic upgrades (rollback is `nix flake update --commit-lock-file && git revert`), and zero "works on my machine" — the flake.lock is the contract.

## Quick reference

| Command | Effect |
|---|---|
| `nix develop` | enter the dev shell from `flake.nix`'s `devShells.default` |
| `nix develop .#packageA` | enter the named dev shell |
| `nix build` | build `packages.default` |
| `nix run` | build + run `packages.default` |
| `nix flake show` | list all outputs |
| `nix flake update` | bump every input to its latest tracked version |
| `nix flake lock --update-input nixpkgs` | bump only `nixpkgs` |
| `nix flake check` | run flake checks (build all outputs, run tests) |

## Common patterns

### Pattern 1 — minimal devShell flake

```nix
{
  description = "Hello-world dev shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs   = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          go_1_23
          gnumake
          jq
        ];
      };
    };
}
```

`nix develop` enters a shell where `go`, `make`, `jq` are on PATH at the exact versions pinned in `flake.lock`.

### Pattern 2 — multi-system support via `flake-utils`

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system}; in {
        devShells.default = pkgs.mkShell { packages = [ pkgs.go ]; };
      });
}
```

Now the same flake works on Linux/macOS Intel + Apple Silicon.

### Pattern 3 — direnv auto-activation

`.envrc`:

```bash
use flake
```

With `nix-direnv` installed, entering the directory auto-activates the flake's dev shell — no `nix develop` ceremony. Cache is reused across `cd` in/out. Tillandsias forge bakes `direnv` and `nix-direnv` for this.

### Pattern 4 — packages output (build a binary)

```nix
outputs = { self, nixpkgs, flake-utils }: flake-utils.lib.eachDefaultSystem (system:
  let pkgs = nixpkgs.legacyPackages.${system}; in {
    packages.default = pkgs.buildGoModule {
      pname = "myapp";
      version = "0.1.0";
      src = ./.;
      vendorHash = "sha256-AAAA...";   # nix build will tell you this on first run
    };
  });
```

`nix build` produces `./result/bin/myapp`. Same binary every time, regardless of the developer's host.

## Common pitfalls

- **Forgetting to commit `flake.lock`** — without it, `nix develop` re-resolves and you're not reproducible. ALWAYS commit `flake.lock`.
- **`nix flake update` without testing** — bumps every input to latest. Run `nix develop`, run tests, THEN commit. Better: `nix flake lock --update-input <one-input>` for surgical updates.
- **`legacyPackages` confusion** — `nixpkgs.legacyPackages.${system}` is the right way to access the package set; `nixpkgs.${system}` doesn't exist. Naming is unfortunate.
- **`buildGoModule` `vendorHash` mismatch** — Nix tells you what hash it computed; copy it in. Failing to update on dep change shows as a build error mentioning hash mismatch.
- **`nix develop` is slow first time** — building/fetching the dev-shell closure. Subsequent invocations are instant (Nix store cached).
- **`use_flake` vs `use flake`** — direnv accepts both, but `use flake` is canonical for nix-direnv (>= 2.x). If `use_flake` doesn't activate, check the integration version.
- **Mixing `nix-shell` (legacy) and `nix develop` (flakes)** — different code paths, different caches. Stick with flakes for new projects.
- **Single-user vs multi-user nix** — Tillandsias forge uses single-user (no daemon, no root). Most flakes work either way; some advanced features (e.g., remote builders) need the daemon.

## See also

- `runtime/forge-container.md` (DRAFT) — Nix is baked into the forge per `forge-bake-nix` change
- `build/cargo.md` (DRAFT) — `crane`/`naersk` flake builders for Rust
- `build/go.md` (DRAFT) — `buildGoModule` baseline
