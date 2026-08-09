# v0.5 continuation handoff after interrupted orchestration

Date: 2026-08-06 (America/Los_Angeles)
Branch: `linux-next`
Cycle base: `318fb7bacc86b63e057bcfb177bac74e7bfd9efe`
Status: active integration; do not release v0.5 yet

## Why this handoff exists

The operator asked the meta-orchestration loop to continue after a security
boundary interrupted the prior run, preserve a durable summary for other
agents, and drain different non-security packets from `./plan`. This document
is the restart point. It deliberately does not reproduce or advance sensitive
git-mirror implementation details; those remain in their dedicated packets.

## Checkpoints already pushed to `linux-next`

- `b49a2c6c` exposes harness identity to local experts.
- `1bf1047b` applies final Containerfile layer squashing.
- `a10a2336` checkpoints regenerated trace indexes.
- `40a8773b` makes local smoke gates hermetic.
- `23f9e4e8` contains anonymous mirror receive damage; it is not the final
  zero-trust authentication design.
- `c9ebd3f5`, `a0ed671f`, and `6043374a` harden/complete the clean-store squash
  acceptance and close order 607-vbbt.
- `038ab5bc` claims the current expert-query and isolated image-benchmark work.

## Current non-security integration wave

### EXPERT query primitives — 606-e2hg

Implementation is complete pending the exact-tree global pre-push gate. The
compiled plan engine and forge-plan MCP now provide:

- exact `desired_release` filtering and structured release projection;
- a separate direct-unsatisfied-upstream primitive (`dependencies-of` /
  `plan_blocked_on`) without changing downstream `blocked-by` semantics;
- word-order-aware natural questions (`X blocked by?` is upstream;
  `blocked by X?` is downstream);
- closed MCP schemas and typed refusal of unknown, empty, duplicate, or
  otherwise ignored constraints.

Focused evidence is green: 95 library tests, 8 CLI tests, the expert
ground-truth harness, the no-unprotected-reader suite, capability-skew tests,
and direct multi-frame MCP probes.

### Final-layer squash benchmark — 608-ijbt

The benchmark is isolated under
`target/container-image-squash-ab/20260806T100224Z/`; it does not use the
operator's shared Podman store. The complete four-image build matrix has
finished and archive/load/start measurements are still running as this handoff
is written.

The build results already falsify the assumption that `--squash` is cost-free
on Podman 5.8.4. Median unchanged rebuilds changed as follows:

| image | layered | squash-new | ratio |
|---|---:|---:|---:|
| git | 5.95 s | 69.94 s | 11.8x slower |
| router | 1.32 s | 62.83 s | 47.6x slower |
| chromium-framework | 1.47 s | 46.71 s | 31.8x slower |
| forge | 10.04 s | 11.22 s | 1.1x slower |

Keep the runtime layer-collapse acceptance intact, but do not describe the
build-cache behavior as preserved. The final benchmark report owns the
keep/revise/revert recommendation and a separate follow-up packet will own a
cache-preserving final-artifact design.

Post-handoff completion: order 608-ijbt finished with 136/136 bounded lifecycle
observations and a **revise** verdict. Clean loaded-store apparent bytes fell
only 0.0372%, compressed archives fell 0.099%, and the complete build matrix
grew 83.85%. Order 617-mxqn is now the ready P0 owner for a cache-preserving
base-plus-one materialization path. The full results and external receipt
location are recorded in the order 608 report.

### Stale browser artifacts — 606-3e2u / 616-nm7q

The source cleanup removes the 5,751-byte disconnected mock and 27,243,632-byte
x86-only ELF, removes the sole Nix copy, archives the obsolete OpenSpec change,
corrects its live references to active specs, and adds a negative absence
fixture. Focused browser/MCP tests are green.

This host's Nix client cannot connect to its daemon, so 606-3e2u is released
`ready` for x86_64+aarch64 output builds and exact closure/output-size evidence.
Do not claim Nix parity yet. Integration review also proved the Nix forge image
never packages the rich OpenCode/Claude MCP config or `host-browser.sh` route;
616-nm7q now owns that explicit flake packaging seam plus the disconnected
eight-tool Rust dispatch family.

## EXPERTS first-person runtime diagnosis

This native Codex session exposes neither `project-plan` nor `project-info` as
callable native tools. Direct stdio JSON-RPC works only after launching the
checkout scripts manually and providing the compiled binary/index paths. With
that diagnostic route:

- project-info correctly reports project type and structured git status;
- forge-plan answers cited methodology questions and the new release/upstream
  queries;
- `plan_status` sees fragment-only packets, while `plan_answer` still refuses
  them because citation provenance/freshness is base-only;
- a clean OpenCode forge does auto-attach and call the experts, so attachment
  is working on that landing path but is not universal.

The next EXPERTS sequence is therefore strict:

1. `606-h9vy` — cite winning fragment fields, verify authority values, and
   compute freshness over base plus fragments;
2. `606-xu52` — expose a concise cited `plan_next` / natural “what's next?”
   result capped at five claimable actions;
3. `606-z389` and harness coverage — make the warmed generic engine and native
   registration transparent on every supported landing path.

## Other durable continuation packets

- `600-c266`: append-event can read a fragment-only packet but writes only to
  the base; implement exclusive event-fragment creation after current
  `main.rs` ownership clears.
- `612-nvf3`: replace Chromium's false `--help` feature probe with a bounded
  real acceptance probe and fixtures.
- `615-x3b8`: reconcile the compiled browser launch boundary with active
  read-only/network/capability specs after 612.
- `606-3e2u`: finish Nix per-architecture output evidence only; source cleanup
  is implemented.
- `616-nm7q`: package the live bridge/config in Nix and connect the eight
  browser tools to the authenticated host route without adding UX.

## Security boundary and release state

The zero-trust git-mirror outcome remains a required v0.5 boundary, but this
continuation does not advance sensitive implementation. Continue from
`plan/issues/git-mirror-zero-trust-audit-2026-08-05.md` and
`plan/issues/git-mirror-pre-receive-native-validation-relay-gap-2026-08-05.md`
under an appropriately authorized agent.

v0.5 is not release-ready: EXPERT provenance/action ranking, browser launch and
MCP wiring, cross-platform evidence, and the mirror authentication boundary
remain nonterminal. No user-visible UX surface was changed in this wave.
