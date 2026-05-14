# Cache Discipline

@trace spec:forge-cache-dual
@cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md, build/nix-flake-basics.md

Build artifacts must leave the project workspace. This forge uses four distinct storage categories. Understand them before your first `cargo build`, `npm install`, or `cargo run`.

## The Four Categories

| Category | Path | Persists? | Shared? | Read/Write | Use for |
|----------|------|-----------|---------|-----------|---------|
| **Shared cache** | `/nix/store/` | Yes | Yes | R only | System libs declared in `flake.nix` |
| **Per-project cache** | `~/.cache/tillandsias-project/` | Yes | No | RW | Build artifacts (target/, node_modules/, .m2/, etc.) |
| **Project workspace** | `/home/forge/src/<project>/` | Yes | RW | RW | Source code, tests, config files (git status sees this) |
| **Ephemeral** | `/tmp/`, unmounted home | No | n/a | RW | Scratch, temp fixtures (gone on container stop) |

**Rule: Build output → per-project cache. Source → workspace. Scratch → /tmp/.**

## Per-Language Environment Variables

The forge pre-sets these. You don't need to set them — just run your tool normally.

| Language/Tool | Env Var | Points To | Verify with |
|---|---|---|---|
| **Rust** | `CARGO_HOME`, `CARGO_TARGET_DIR` | `~/.cache/tillandsias-project/cargo/{,target}` | `cargo metadata --format-version 1 \| jq .target_directory` |
| **Go** | `GOPATH`, `GOMODCACHE` | `~/.cache/tillandsias-project/go/{,pkg/mod}` | `go env GOPATH` |
| **Maven** | `MAVEN_OPTS` (`-Dmaven.repo.local=...`) | `~/.cache/tillandsias-project/maven/` | `mvn help:describe` (look at -Dmaven.repo.local) |
| **Gradle** | `GRADLE_USER_HOME` | `~/.cache/tillandsias-project/gradle/` | `gradle properties \| grep gradle.user.home` |
| **Flutter/Dart** | `PUB_CACHE` | `~/.cache/tillandsias-project/pub/` | `pub cache list` |
| **npm** | `npm_config_cache` | `~/.cache/tillandsias-project/npm/` | `npm config get cache` |
| **Yarn** | `YARN_CACHE_FOLDER` | `~/.cache/tillandsias-project/yarn/` | `yarn config get cacheFolder` |
| **pnpm** | `PNPM_HOME` | `~/.cache/tillandsias-project/pnpm/` | `pnpm config get dir` |
| **uv** | `UV_CACHE_DIR` | `~/.cache/tillandsias-project/uv/` | `uv config --show` |
| **pip** | `PIP_CACHE_DIR` | `~/.cache/tillandsias-project/pip/` | `pip cache dir` |
| **OpenCode/Node** | `npm_config_cache` | Per-project | `npm config get cache` |

Just run the tool. The env vars redirect output for you.

## What Goes Where (By Example)

### ✅ Cargo build → per-project cache

```bash
$ cd /home/forge/src/my-rust-app
$ cargo build --release
# Output: ~/.cache/tillandsias-project/cargo/target/release/my-rust-app
# NOT: ./target/  (which would pollute git)
```

Verify:
```bash
$ cargo metadata --format-version 1 | jq .target_directory
# expect: /home/forge/.cache/tillandsias-project/cargo/target
```

### ✅ npm install → per-project cache

```bash
$ cd /home/forge/src/my-web-app
$ npm install
# Output: node_modules stays WHERE?
# Answer: npm caches in ~/.cache/tillandsias-project/npm/
# node_modules may land in workspace (that's OK — source control ignores it via .gitignore)
```

Verify:
```bash
$ npm config get cache
# expect: /home/forge/.cache/tillandsias-project/npm
```

### ✅ Shared deps via nix → /nix/store/ (RO)

```bash
# flake.nix declares the dep
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  outputs = { self, nixpkgs }: {
    devShells.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.mkShell {
      packages = [ nixpkgs.legacyPackages.x86_64-linux.openssl ];
    };
  };
}

# Run nix develop on the HOST (not inside this container)
$ nix develop
# Forge sees /nix/store/<hash>-openssl-3.2/  via RO mount on next attach
```

### ✅ Throwaway scratch → /tmp/

```bash
$ cd /tmp
$ tar -xzf big-fixture.tar.gz
# Do work
$ rm -rf big-fixture.tar.gz extracted/
# Gone on container stop
```

### ❌ Don't write build output to workspace

```bash
# BAD: cargo build (without CARGO_TARGET_DIR set correctly)
$ cargo build --manifest-path src/Cargo.toml
# pollutes git workspace

# GOOD: env vars are pre-set
$ cargo build
# uses CARGO_TARGET_DIR automatically
```

### ❌ Don't try to share artifacts across projects

```bash
# BAD: assuming node_modules from ProjectA works in ProjectB
$ cp -r ../project-a/node_modules ./
# Different lockfiles, different versions → broken builds

# GOOD: each project gets its own per-project cache
$ npm install  # uses ~/.cache/tillandsias-project/npm/
# Shared at the npm registry level (nix can share deeper if needed)
```

## Common Gotchas

**"My build is huge and slow"**  
→ Check `cargo metadata --format-version 1` (or equivalent for your tool)  
→ Is output going to `/tmp/` or workspace instead of per-project cache?  
→ Verify env var is set: `echo $CARGO_TARGET_DIR`

**"Build succeeds but files are missing on next attach"**  
→ Are you writing to `/tmp/` or ephemeral home?  
→ Those dirs are gone on container stop. Use `~/.cache/tillandsias-project/` for state that should survive.

**"nix develop isn't picking up my deps"**  
→ Run `nix develop` ON THE HOST, not inside this container  
→ The forge's `/nix/store/` is RO; new builds happen host-side

**"npm install creates node_modules but they don't persist"**  
→ node_modules location is tool-specific  
→ The npm cache (`~/.cache/tillandsias-project/npm/`) persists  
→ Re-run `npm install` on next attach to restore node_modules from cache

## Cleanup

Cache grows over time. Occasional housekeeping:

```bash
# From the HOST (not inside this container):
rm -rf ~/.cache/tillandsias/forge-projects/<project>/

# Safe to do — just re-runs the download on next attach
# Nix store cleanup:
nix-collect-garbage  # removes unreferenced entries from /nix/store/
```

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — four-category model in depth
- `cheatsheets/runtime/forge-shared-cache-via-nix.md` — nix as the shared-cache entry point
