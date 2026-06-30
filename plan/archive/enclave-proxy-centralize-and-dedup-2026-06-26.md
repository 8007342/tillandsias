# Enclave Proxy: Centralize Injection and Fix NO_PROXY Drift

**Status:** `completed`
**Owner:** linux
**Date:** 2026-06-26
**Completed:** 2026-06-27T03:40Z
**Trace:** `spec:proxy-container`, `spec:enclave-network`

## Problem

`crates/tillandsias-headless/src/main.rs` injects `HTTP_PROXY`, `HTTPS_PROXY`,
`http_proxy`, `https_proxy`, `NO_PROXY`, `no_proxy` env vars in at least **five
separate locations**:

| Location | Line approx. | Notes |
|---|---|---|
| `build_stack_common_args` | 1695 | Shared base — correct injection point |
| `build_git_run_args` | 1896 | Redundant; shorter NO_PROXY list |
| `build_inference_run_args` | 1978 | Redundant; uses ENCLAVE_NO_PROXY |
| `build_forge_common_args` | 2728 | Redundant |
| `build_forge_agent_run_args` (Command builder) | 6478 | Redundant |

The BigPickle fix (commit `c8f59e24`) added a sixth injection to
`build_git_run_args` because the git container was not getting proxy vars
from `build_stack_common_args`. This reveals the underlying problem: it is
unclear which containers call `build_stack_common_args` and which bypass it.

The `build_git_run_args` injection also uses a **shorter NO_PROXY list**
(`localhost,127.0.0.1,git-service,tillandsias-git,vault,inference`) that omits
entries from `ENCLAVE_NO_PROXY` (`0.0.0.0,::1,proxy,10.0.42.0/24`). This
creates a silent failure mode if git tries to reach an internal service whose
hostname is in `ENCLAVE_NO_PROXY` but not in the shorter list.

## Goal

A single, canonical injection point for proxy env vars. No per-container
builder should need to know the proxy address or the NO_PROXY list.

## Option A: containers.conf (preferred if feasibility research supports it)

Write `~/.config/containers/containers.conf` with proxy env vars at enclave
start time (or as a one-time setup step). Podman 4.0+ injects these into
every container automatically. Remove all proxy env var injection from the
Rust launcher code.

Pro: the Rust code becomes silent on proxy matters; a new container added
tomorrow gets proxy routing for free.  
Con: affects all containers run by this user account, not just enclave
containers. Acceptable for a dedicated `tillandsias` service account.

## Option B: single injection in build_stack_common_args (minimal change)

Verify that EVERY container built by the launcher calls
`build_stack_common_args`. If any container bypasses it (as the git container
apparently does), route it through. Remove all other injection sites.

This preserves the current architecture but eliminates redundancy.

## Exit Criteria

- Exactly **one** location in the codebase injects proxy env vars into
  containers (either containers.conf or `build_stack_common_args`).
- The NO_PROXY list is defined as `ENCLAVE_NO_PROXY` in exactly one place in
  the Rust code (already done) and used everywhere.
- `cargo test git_run_args` and `cargo test proxy` pass.
- `litmus:git-mirror-safe-refspec-push` passes.
- A comment at the injection point cites `cheatsheets/runtime/enclave-proxy-patterns.md`
  as the justification for using env vars rather than a transparent proxy.

## Files to change

- `crates/tillandsias-headless/src/main.rs` — remove redundant proxy env var
  injections from `build_git_run_args`, `build_inference_run_args`,
  `build_forge_common_args`, `build_forge_agent_run_args`
- `~/.config/containers/containers.conf` (Option A only)

## Depends on

- `enclave-transparent-proxy-feasibility` (order 99) — the chosen option may
  change based on the TPROXY verdict
