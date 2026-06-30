# ZeroClaw Unauthorized Binary Release — Violation Report

**Status:** `completed`
**Owner:** linux
**Date:** 2026-06-27
**Order:** 114
**Severity:** CRITICAL — Architecture + Authorization Violation

## Executive Summary

Release `v0.3.260627.1` shipped a second binary `tillandsias-zeroclaw-linux-x86_64`
without Tlatoāni approval. When a user ran `curl install.sh | bash` they received
an unexpected binary at `~/.local/bin/tillandsias-zeroclaw`. This violates
Tillandsias' foundational "ONE SINGLE TINY BINARY, ZERO DEPENDENCIES" principle
and was not authorized by the project owner.

## Violations Found

### Violation 1: Unauthorized artifact introduction
`tillandsias-zeroclaw` was added as a second release binary (order 111) without
Tlatoāni's explicit approval. The project has an absolute rule: **no new release
artifacts without owner approval**. An agentic work-loop cycle introduced it as a
"packaging" step and it shipped in the next release.

### Violation 2: Architecture — separating what must be one binary
The zeroclaw MCP server ran as a host-resident Unix socket server accepting
arbitrary JSON-RPC 2.0 tool invocations. Any local process could connect and
invoke host-level shell commands (forge delegate, shell exec, file read, file
write, list projects). This is a standalone process with no isolation, running
as the user, bypassing all container security flags.

The Tillandsias principle is ONE binary. Any MCP functionality must be built into
`tillandsias` (the headless binary) via a runtime flag (e.g. `--mcp orchestrator`),
not as a separate artifact.

### Violation 3: Naming leaks implementation details
The binary was called `tillandsias-zeroclaw`, naming it after the implementation
that _uses_ it (ZeroClaw) rather than after the product that _owns_ it (Tillandsias).
Architectural principle: module names must not reference callers. It is a
Tillandsias MCP server, not a "ZeroClaw" server. The naming exposed an internal
implementation detail as a user-visible artifact name.

### Violation 4: Shell injection risk in MCP dispatch
`zeroclaw.forge_delegate` in `crates/tillandsias-zeroclaw/src/server.rs` passed
caller-supplied prompt text to `bash -c` via Rust Debug format (`{prompt:?}`).
Debug quoting is not shell-safe — a prompt containing `'; rm -rf ~; '` would
execute. This is a command injection vulnerability in a host-resident process.

### Violation 5: Host-resident MCP socket accessible to any local process
The zeroclaw server listened on a Unix socket that any local process could
connect to without authentication. Combined with the shell dispatch capability,
this is a local privilege escalation surface.

## Remediation Applied (order 114)

All changes applied in a single commit, `./build.sh --check` verified clean:

1. **`scripts/install.sh`** — removed `ZEROCLAW_ASSET` variable and the entire
   zeroclaw download/install block (lines 9 and 198-207).

2. **`.github/workflows/release.yml`** — removed:
   - `nix build -L .#tillandsias-zeroclaw-x86_64-musl` build step
   - `install -m 0755 result-zc/bin/tillandsias-zeroclaw release-artifacts/...` collection
   - `file release-artifacts/tillandsias-zeroclaw-linux-x86_64 | grep -F "statically linked"` check
   - `test -f tillandsias-zeroclaw-linux-x86_64` and `.cosign.bundle` verification lines

3. **`flake.nix`** — removed `tillandsias-zeroclaw-x86_64-musl` build target
   definition (lines 117-130) and its entry in `packages.inherit`.

4. **`Cargo.toml`** — removed `"crates/tillandsias-zeroclaw"` workspace member
   and `tillandsias-zeroclaw = { path = "crates/tillandsias-zeroclaw" }` workspace dep.

5. **`crates/tillandsias-zeroclaw/`** — entire directory deleted.

6. **`~/.local/bin/tillandsias-zeroclaw`** — local binary removed.

## Future Direction

If MCP server functionality is needed, it MUST be built into the `tillandsias`
headless binary under a runtime flag:

```
tillandsias --mcp orchestrator
```

This preserves the one-binary architecture, keeps all socket handling under the
same binary's security envelope, and makes the naming product-owned (Tillandsias)
rather than caller-referenced (ZeroClaw). Any such addition requires explicit
Tlatoāni approval before implementation begins.

## Prevention

- Agentic work loops MUST NOT introduce new release artifacts without an explicit
  Tlatoāni approval event recorded in `plan/index.yaml`.
- The `advance-work-from-plan` skill MUST treat "add new release artifact" as a
  blocked status requiring human sign-off, not an autonomous packaging step.
- Release workflow validation steps that check for artifact presence act as a
  guard — adding new artifact checks without a matching approval is a signal.

## Related

- `plan/issues/vault-credential-host-exposure-audit-2026-06-27.md` — credential audit (order 113)
- `plan/issues/zeroclaw-progress.md` — prior zeroclaw planning (superseded)
- Orders 110-111: zeroclaw binary path + release packaging (now fully reverted)
