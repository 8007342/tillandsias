---
tags: [forge, cache, ephemeral, persistent, mounts, methodology, paths, host-chromium]
languages: []
since: 2026-04-25
last_verified: 2026-04-25
sources:
  - https://github.com/8007342/tillandsias/blob/main/openspec/changes/forge-cache-architecture/proposal.md
  - https://github.com/8007342/tillandsias/blob/main/crates/tillandsias-core/src/container_profile.rs
  - https://github.com/8007342/tillandsias/blob/main/images/default/lib-common.sh
authority: high
status: current
---

# Forge paths — ephemeral vs persistent

@trace spec:forge-cache-architecture, spec:forge-cache-dual
@cheatsheet runtime/forge-shared-cache-via-nix.md, build/nix-flake-basics.md

## Provenance

This is project-internal architecture; the authority is the Tillandsias spec + source.
- OpenSpec change `forge-cache-architecture` proposal: <https://github.com/8007342/tillandsias/blob/main/openspec/changes/forge-cache-architecture/proposal.md>
- Mount source code: <https://github.com/8007342/tillandsias/blob/main/crates/tillandsias-core/src/container_profile.rs>
- Env var exports: <https://github.com/8007342/tillandsias/blob/main/images/default/lib-common.sh>
- **Last updated:** 2026-04-25

## Use when

You're an agent (or human) writing files inside the forge container and need to know **what survives**, **what's gone on next attach**, and **what would leak across projects**. Read this BEFORE doing any I/O the first time you attach.

## The four categories — at a glance

| Category | Forge path | Survives container stop? | Visible to OTHER projects? | Read/Write |
|---|---|---|---|---|
| **Shared cache** | `/nix/store/` | Yes (host-managed) | Yes (all projects share) | **R only** |
| **Per-project cache** | `/home/forge/.cache/tillandsias-project/` | Yes (per-project) | **No** — isolated | RW |
| **Project workspace** | `/home/forge/src/<project>/` | Yes (your git repo) | **No** — isolated | RW |
| **Ephemeral** | `/tmp/`, unmounted home dirs, anything not in the above three | **NO** — gone on stop | n/a | RW |

## Where to write what

### Build artifacts that are expensive to rebuild → per-project cache

Cargo target/, Maven .m2/, Gradle ~/.gradle/, Flutter pub-cache, npm/yarn/pnpm caches, pip wheel cache, Go module cache, uv cache. Per-language env vars are pre-set in the forge to redirect each tool here:

| Tool | Env var | Subdir under per-project cache |
|---|---|---|
| Cargo | `CARGO_HOME`, `CARGO_TARGET_DIR` | `cargo/`, `cargo/target/` |
| Go | `GOPATH`, `GOMODCACHE` | `go/`, `go/pkg/mod/` |
| Maven | `MAVEN_OPTS` (`-Dmaven.repo.local=...`) | `maven/` |
| Gradle | `GRADLE_USER_HOME` | `gradle/` |
| Flutter / Dart | `PUB_CACHE` | `pub/` |
| npm | `npm_config_cache` | `npm/` |
| Yarn | `YARN_CACHE_FOLDER` | `yarn/` |
| pnpm | `PNPM_HOME` | `pnpm/` |
| uv | `UV_CACHE_DIR` | `uv/` |
| pip | `PIP_CACHE_DIR` | `pip/` |

You don't need to set these — they're exported by `lib-common.sh` at every entrypoint. Just run your tool normally.

### Source code → project workspace

`/home/forge/src/<project>/` is your git repo. Source code, project config (`Cargo.toml`, `package.json`, `pyproject.toml`, etc.), tests, READMEs. This is what `git status` cares about.

### Throwaway scratch → /tmp/

Big intermediate files you don't want to keep, test fixtures generated for one run, anything you'd `rm -rf` at the end of the script anyway. `/tmp/` is the container's own writable layer — gone on container stop.

### Shared deps → don't write directly; let nix do it

`/nix/store/` is read-only from the forge's perspective. If your project needs a system library available to multiple projects (and you want it cached host-wide), declare it in your project's `flake.nix` — the host populates the nix store via `nix build`, and your forge sees the result via the RO mount. See `cheatsheets/runtime/forge-shared-cache-via-nix.md`.

## Anti-patterns the methodology will flag

- **Writing build output to the project workspace** — `target/`, `node_modules/`, `build/`, `dist/`, `.gradle/`, `.dart_tool/` cluttering your git repo. The env vars above redirect this. If a tool doesn't honor its env var, file a `RUNTIME_LIMITATIONS_NNN.md` (see `cheatsheets/runtime/runtime-limitations.md`).
- **Committing downloaded JARs or vendored binaries** — happened in the `../java/` test agent (committed Adoptium JDK + Log4j JAR). The download telemetry will flag any large file written to the project workspace whose source was a network URL with `reason="workspace-anti-pattern"` (see `cheatsheets/runtime/forge-cache-discipline.md` if/when it lands).
- **Writing big files to `/tmp/` and forgetting** — they're gone on next attach but they take space NOW. Free them eagerly in long-running scripts.
- **Trying to `pip install --user`** — `~/.local/` is in the unmounted-home ephemeral category. Use a per-project venv under the project workspace (which redirects to the per-project cache via `PIP_CACHE_DIR`), or use `pipx` for global tools (already pre-installed: ruff, black, mypy, pytest, httpie, uv, poetry).
- **Trying to write to `/nix/store/`** — fails with EROFS. The shared cache is RO from the forge's seat. Add the dep to `flake.nix` instead.

## Common pitfalls

- **Confusing the per-project cache with `~/.cache/`** — `~/.cache/` (i.e. `/home/forge/.cache/`) is mostly NOT bind-mounted; only the specific subdir `tillandsias-project/` IS. Other tools that write to `~/.cache/something-else/` will lose their state on container stop. If you find a tool that needs persistence outside `tillandsias-project/`, file a RUNTIME_LIMITATIONS report.
- **Cross-project leak via `/tmp/`** — `/tmp/` is per-container so cross-project leak via `/tmp` is impossible (different containers, different /tmp). But beware of using `/tmp/` for state you wanted persistent — it's gone.
- **Per-project cache size growth** — nothing GCs `~/.cache/tillandsias/forge-projects/<project>/` automatically. If a project's cache grows huge, you can `rm -rf ~/.cache/tillandsias/forge-projects/<project>/` from the host (no container needs to be running). Treat this as occasional housekeeping, not part of normal flow.
- **Forge user can't see other projects** — by design. If your project needs to reference files in another project's workspace, you're fighting the architecture. Cross-project sharing happens via git (commit + clone) or via nix (publish a flake).

## Verification

```bash
# Inside any forge container, confirm the four mounts are correctly set up:
mount | grep -E '(nix/store|tillandsias-project|src/)'

# Confirm env vars resolve into per-project cache:
printenv | rg -i '(cache|home|target|gradle|cargo)' | sort

# Quick check that cargo writes to the right place:
cd /home/forge/src/<project>
cargo metadata --format-version 1 | jq .target_directory
# expect: /home/forge/.cache/tillandsias-project/cargo/target
```

## Host-side data: the bundled Chromium binary tree

@trace spec:host-chromium-on-demand

`scripts/install.sh` (and the `tillandsias --install-chromium` subcommand) install a pinned Chrome for Testing build into the user's **data** directory — NOT the cache directory. This is host-side, NOT forge-side, but it falls under the same "regenerable only by an explicit installer run, never automatically" category that the per-project cache (above) does, and the rationale is identical: caches are by spec deletable at any time but the running tray cannot regenerate the Chromium binary on its own. If the user wipes the cache directory the tray must keep working; if they wipe the data directory they explicitly opted out.

| Platform | Install root | Regenerable by | Auto-cleaned? |
|---|---|---|---|
| Linux | `${XDG_DATA_HOME:-$HOME/.local/share}/tillandsias/chromium/` | `tillandsias --install-chromium` (or re-running the curl installer) | No |
| macOS | `$HOME/Library/Application Support/tillandsias/chromium/` | same | No |
| Windows | `%LOCALAPPDATA%\tillandsias\chromium\` | same | No |

A `current` symlink (Unix) or directory junction (Windows) in the install root points at the active version. At most TWO version subdirectories coexist: the active one and the immediately-previous one (rollback safety net). Older versions are GC'd by the installer at the end of every successful install. See `openspec/specs/host-chromium/spec.md` for the full requirement set.

## See also

- `runtime/forge-shared-cache-via-nix.md` — why nix is the right shared-cache entry
- `runtime/forge-container.md` (DRAFT) — broader runtime contract
- `runtime/runtime-limitations.md` (DRAFT) — how to report a missing tool / capability
- `build/nix-flake-basics.md` — declaring shared deps via flake
- `security/owasp-top-10-2021.md` — SHA-256-pinned-binary pattern for the bundled Chromium download
