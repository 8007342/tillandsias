# Nix-First Methodology

@trace spec:forge-bake-nix
@cheatsheet runtime/forge-shared-cache-via-nix.md, build/nix-flake-basics.md

When starting a NEW project, Nix is the entry point for declaring build inputs and system dependencies — before `cargo init`, `npm init`, or any language-specific tool.

## Why Nix First?

Without nix, each project downloads its own copy of every system lib (OpenSSL, libpq, protoc, etc.). With nix, you declare once in `flake.nix`; the forge shares the compiled result across all projects via `/nix/store/`.

**Result**: faster builds, smaller cache footprints, reproducible environments across machines.

## Quickstart

```bash
$ cd /home/forge/src/my-new-project
$ git init
$ nix flake init                    # scaffolds flake.nix
$ nix develop                       # runs on the HOST (not in this container)
# Inside the devShell:
$ cargo init                        # or npm init, python -m venv, etc.
```

## Flake Structure

A minimal `flake.nix` declares inputs (what you need) and outputs (what you build):

```nix
{
  inputs = {
    # Use a pinned nixpkgs snapshot — all repos use the same snapshot by default
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in {
    # Development shell — tools available when you `nix develop`
    devShells.x86_64-linux.default = pkgs.mkShell {
      packages = [
        pkgs.cargo
        pkgs.rustc
        pkgs.openssl
        pkgs.pkg-config
      ];
    };
  };
}
```

## Common Patterns

### Pattern 1: Rust project

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  outputs = { self, nixpkgs }: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in {
    devShells.x86_64-linux.default = pkgs.mkShell {
      packages = with pkgs; [ cargo rustc rustfmt clippy openssl pkg-config ];
    };
  };
}
```

After `nix develop` (on the host), you can `cargo build` inside the forge.

### Pattern 2: Node.js project

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  outputs = { self, nixpkgs }: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in {
    devShells.x86_64-linux.default = pkgs.mkShell {
      packages = with pkgs; [ nodejs_20 yarn ];
      # Optional: pin Node version, add native build tools
    };
  };
}
```

### Pattern 3: Python project (local venv, nix for system libs)

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  outputs = { self, nixpkgs }: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in {
    devShells.x86_64-linux.default = pkgs.mkShell {
      packages = with pkgs; [ python311 poetry postgresql ];
      # poetry will create .venv in the workspace; postgres CLI is in PATH
    };
  };
}
```

## What Goes in flake.nix vs What Doesn't

| Does go | Doesn't go |
|---------|-----------|
| System libs (openssl, libpq, protoc) | Your app's source code |
| Language runtimes (rustc, node, python3) | Git repos you'll clone |
| Build tools (cargo, npm) | Environment-specific secrets |
| Native libraries (libpcre, libffi) | User preferences or per-machine config |

## Where Nix Integrates with This Forge

1. **Host side (your machine)**: You run `nix develop` or `nix build`
2. **Forge side (inside this container)**: You see the result via `/nix/store/<hash>-<pkg>/` (RO mount)
3. **No building inside the forge**: The forge has nix installed but can't write to `/nix/store/` (EROFS by design)

## Common Errors

**Error: "nix: command not found"**  
→ You're running this inside the forge, not on the host  
→ Exit the container: `exit` or Ctrl+D  
→ Run `nix develop` on your local machine first, then attach to the forge

**Error: "EROFS: Read-only file system /nix/store"**  
→ You tried to write to `/nix/store/` inside the forge  
→ Declare the dep in `flake.nix`, run `nix develop` on the host, then re-attach to the forge

**Error: "flake.nix: No such file or directory"**  
→ Run `git init && nix flake init` at the project root first  
→ Or copy/paste one of the patterns above into a new `flake.nix`

## Checking It Works

```bash
# After `nix develop` on the host, attach to the forge:
$ which openssl          # should print /nix/store/<hash>-openssl-3.x/bin/openssl
$ openssl version        # should work
$ echo $PKG_CONFIG_PATH  # should include /nix/store/<hash>-pkg-config/lib/pkgconfig
```

## Non-Nix Projects

Existing projects (without `flake.nix`) use per-project caches for their tools:
- Maven uses `~/.cache/tillandsias-project/maven/`
- npm uses `~/.cache/tillandsias-project/npm/`
- Gradle uses `~/.cache/tillandsias-project/gradle/`

These still work fine — they just re-download per project. Nix-first is a **recommendation for new projects**, not a mandate for existing ones.

## Sources of Truth

- `cheatsheets/runtime/forge-shared-cache-via-nix.md` — why nix is content-addressed and safe to share
- `cheatsheets/build/nix-flake-basics.md` — full flake authoring patterns and debugging
