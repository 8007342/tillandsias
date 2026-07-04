# Impl (prereq): guarantee a persistent, writable tool cache mount on forge launch — 2026-07-04

- class: enhancement (forge cache)
- filed: 2026-07-04
- owner: linux
- status: pending (blocked on the research persistence-answer)
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
