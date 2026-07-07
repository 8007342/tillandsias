# Impl (prereq): guarantee a persistent, writable tool cache mount on forge launch — 2026-07-04

- class: enhancement (forge cache)
- filed: 2026-07-04
- owner: linux
- status: done
- depends_on: forge-image-creation-vs-firstrun-split-research-2026-07-04.md
- trace: spec:forge-cache-dual

## Why (prerequisite for the whole first-run migration)

First-run tool installs only make sense if they PERSIST across the forge's `--rm`.
The research packet shows the live `build_forge_agent_run_args` path mounts no
persistent cache for `$CARGO_HOME` / `$NPM_CONFIG_PREFIX`
(`/home/forge/.cache/tillandsias-project`), so today those installs would be lost
each launch. This packet ensures a persistent, writable cache is mounted BEFORE
any tool is migrated to first-run.

## Scope

- Confirm (from the research) whether a persistent cache already mounts. If it
  does, this packet is a no-op verification + litmus. If not:
- Add a persistent mount for the forge tool/package cache — a host bind-mount of
  `~/.cache/tillandsias/<project>/` (or a shared `~/.cache/tillandsias/tools/`
  for cross-project tool reuse) → `/home/forge/.cache/tillandsias-project` — in
  `build_forge_agent_run_args` (and any sibling launch path), matching what
  lib-common already assumes for `$CARGO_HOME` / `$NPM_CONFIG_PREFIX`.
- Decide cross-project sharing: tool binaries (cargo-nextest etc.) are project-
  independent and SHOULD live in a shared cache; per-project build artifacts stay
  per-project. Consider a shared `tools/` cache + per-project `target/` cache.
- Keep the mount COLD (disk-backed), never HOT/tmpfs (these are big, write-once-
  read-many). Respect the ephemeral-vs-persistent cheatsheet.

## Exit criteria
- A forge relaunch shows the tool/package cache path persists (`podman inspect`
  evidence: a host bind-mount or named volume backs it).
- A litmus asserts `build_forge_agent_run_args` mounts the persistent cache to the
  path lib-common points `$CARGO_HOME` / `$NPM_CONFIG_PREFIX` at.
- No HOT/tmpfs regression; `./build.sh --check` + `--test` pass.

## DONE 2026-07-04

`build_forge_agent_run_args` now mounts a per-project podman NAMED volume
`tillandsias-forge-cache-<project>` (via `forge_tool_cache_volume`) at
`/home/forge/.cache/tillandsias-project` — the exact path lib-common points
`$CARGO_HOME`/`$NPM_CONFIG_PREFIX` at. So FIRST_RUN tool/harness installs (orders
180/181) now survive the forge's `--rm`.

**Design decision (locked):** a NAMED volume, not a host bind-mount. Podman
auto-creates it on run and does not remove it on `--rm` (persistence), and it
carries ZERO host-`$HOME` reference — so it can never become a credential/config
leak path (strictly safer than a `~/.cache` bind-mount, and it dodges the
`launch_forge_agent_does_not_mount_user_home` guard by construction). Per-project
so caches never cross project boundaries.

Guard test refined: the blanket `joined.contains(".cache"/".config")` asserts (which
wrongly flagged the container-side TARGET `/home/forge/.cache/...`) are now
SOURCE-scoped — they still forbid a host `.cache`/`.config` mount source, but allow
the legitimate container target + named volumes.

Verified: `cargo build --features vault,tray` green, `./build.sh --check` green, full
headless suite 244 passed / 0 failed (incl. new
`forge_agent_mounts_persistent_tool_cache_named_volume` + the refined guard), and
`litmus:forge-persistent-tool-cache-mount-shape` (4/4). Promoted 180 + 181 to ready.

Follow-ups (noted, not blocking): (1) a shared cross-project tools cache (cargo tool
binaries are project-independent — a shared volume would avoid re-installing per
project); (2) named-volume pruning on `--cache-clear`; (3) the OpenCode launch path
(build_opencode_forge_args) if it needs the same persistence.
