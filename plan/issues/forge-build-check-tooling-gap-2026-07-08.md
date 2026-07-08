# Forge Build Check Tooling Gap

**Date:** 2026-07-08
**Classification:** optimization
**Host:** forge
**Observed by:** forge-codex-20260708T0000Z

## Observation

`./build.sh --check` cannot run in this forge environment before it reaches the
workspace Rust checks:

```text
ERROR: podman must be installed and available on PATH
[build] Failed to setup podman registries (non-fatal, build may continue)
[build] Failed to generate CA cert for dev proxy
[build] Checking Rust formatting...
[build] Missing host build tools: file
[build] Install the Fedora build dependencies, then rerun this command.
```

This forge is already running inside a Podman container, so missing host Podman
inside the forge is expected and should not be treated as a tool to install
there. The targeted Rust test for order 237 passes with a temporary `HOME`, but
the standard integration gate is unavailable inside this forge until the check
path distinguishes in-forge execution from host execution and either skips host
Podman setup or delegates it to an outer host.

## Impact

Forge agents working on small Rust/script slices cannot run the repo-standard
`./build.sh --check` gate from inside the forge, so they either need to fall
back to narrower checks or hand off validation to a mutable Linux host. The
current error text is also misleading in forge because it asks for Podman on
PATH even though the forge is nested inside the runtime substrate.

## Smallest Next Action

Teach `./build.sh --check` to detect `TILLANDSIAS_HOST_KIND=forge` and skip
host-Podman registry/proxy setup for check-only paths, or emit a precise
delegation message when an outer-host Podman operation is genuinely required.
Separately, decide whether the forge image should include `file`, or whether the
metadata check that needs it can be made optional/fallback-driven in forge.

## Verifiable Closure

A forge session can run:

```bash
./build.sh --check
```

and reach the Rust type-check stage without failing on missing host `podman`.
If `file` is still required, the error names only that missing metadata tool and
does not suggest installing Podman inside the forge.

## Resolution

2026-07-08T19:23Z: Implemented in `build.sh`.

- `TILLANDSIAS_HOST_KIND=forge ./build.sh --check` now skips host Podman
  registry setup and host dev-cache setup, then proceeds to formatting,
  type-check, and clippy.
- `_require_host_build_tools` no longer requires `file` for `--check`; `file`
  remains required for `--install`, where the portable launcher validation uses
  it.
- Added `scripts/test-build-sh-forge-check-only.sh` as the targeted regression
  check for the forge check-only branch.

Evidence:

- `scripts/test-build-sh-forge-check-only.sh` — PASS.
- `TILLANDSIAS_HOST_KIND=forge ./build.sh --check` — PASS; host Podman setup
  skipped, Rust fmt/type-check/clippy all passed.
- `./build.sh --check` — PASS on linux_mutable; normal non-forge Podman
  registry setup still ran before fmt/type-check/clippy.
