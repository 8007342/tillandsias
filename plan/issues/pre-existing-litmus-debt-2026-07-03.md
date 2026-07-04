# Pre-existing pre-build litmus debt (9 failing) — 2026-07-03

- class: research (test debt capture)
- filed: 2026-07-03
- owner: linux
- status: ready
- trace: methodology/litmus.yaml, plan/loop_status.md

## Context

Running `./build.sh --ci-full` before the v0.3.260703.1 release surfaced 9 failing
pre-build litmus tests. A worktree comparison against `origin/main` (the released
v0.3.260702.2) shows the **exact same 9** fail there — i.e. they are pre-existing
debt that the release path does not gate on (release builds the Nix musl artifact;
it does not run the `--ci-full` litmus suite). This session's changes introduced
**zero** new litmus failures (verified by set-diff main↔HEAD).

Captured here so the debt is tracked rather than lost. NOT a v0.3.260703.1 release
blocker: the P0 vault-SELinux fix ships a tree that is litmus-identical to the last
release plus a critical crash fix.

## The 9 failing litmus (each needs its own triage packet)

- `litmus:vault-entrypoint-hardened-shape` (STEP 4) — expects the host bootstrap
  to delete `/run/vault-handover`; the order-138 shred rewrote that cleanup to a
  `dd`-overwrite-then-`rm` `sh -c`, which the litmus's shape matcher no longer
  recognizes. Likely just needs the litmus updated to match the shred form.
- `litmus:vault-github-token-capture-shape`
- `litmus:gh-auth-script-shape`
- `litmus:github-credential-health-shape`
- `litmus:podman-secrets-integration-shape`
- `litmus:inference-container-implementation-shape`
- `litmus:macos-tray-architectural-invariants`
- `litmus:pty-attach-project-threading-symmetric`
- `litmus:cheatsheet-host-image-sync`

## Next action

Triage each: is the litmus stale (implementation moved, update the litmus) or is
the implementation genuinely out of spec (fix the code)? Start with
`vault-entrypoint-hardened-shape` (clearly a stale matcher after the shred). File
a per-litmus reduction packet as each is diagnosed. Also relevant: order 169
(wire the policy checkers + these litmus into CI so this debt fails the build
instead of silently shipping).
