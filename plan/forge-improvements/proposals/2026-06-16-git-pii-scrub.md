---
title: Scrub Git PII from container environment
gap: "isolation_or_privacy_risks: GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_COMMITTER_NAME, GIT_COMMITTER_EMAIL expose real user identity to all container processes"
category: env-var
status: accepted
proposed_at: 2026-06-16T08:00:00Z
triaged_at: 2026-06-16T09:40:00Z
triage_decision: >
  ACCEPTED into a privacy work packet (privacy/forge-git-identity-anonymization,
  plan/index.yaml order 53). Confirmed real exposure: container_profile.rs and
  main.rs:4122-4125 deliberately inject the host user's real GIT_AUTHOR_*/
  GIT_COMMITTER_* into the forge. The fix MUST preserve git commit attribution
  inside the forge — use an anonymized/forge identity, NOT bare removal (bare
  unset would break enclave-mirror commits). See triage note at end.
changes:
  - file: images/default/entrypoint-forge-opencode.sh
    description: |
      Unset or scrub GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_COMMITTER_NAME,
      GIT_COMMITTER_EMAIL at entrypoint time to prevent personal identity
      leakage to forge container processes.
---

## Gap

Diagnostic runs (`diagnostics_20260604T002348Z-summary.md`,
`diagnostics_20260614T070420Z-summary.md`) identified that Git environment
variables containing real user identity information are visible inside the
forge container:

- `GIT_AUTHOR_NAME=Tlatoāni`
- `GIT_AUTHOR_EMAIL=bulloncito@gmail.com`
- `GIT_COMMITTER_NAME=Tlatoāni`
- `GIT_COMMITTER_EMAIL=bulloncito@gmail.com`

These values propagate from the host environment into the forge container and
are visible to all processes running inside it.

## Evidence

- `diagnostics_20260604T002348Z-summary.md`: isolation_or_privacy_risks — Git PII exposure
- `diagnostics_20260614T070420Z-summary.md`: recurring observation
- Also flagged in `forge-enhancements-curated-toolchain-backlog-2026-05-29.md`
  Update 2026-05-29T08:21Z section

## Privacy/Isolation Assessment

This is a **privacy leak** — the container should not have access to the host
user's real identity. While the forge is already inside an enclave network,
any output captured from the container (logs, build artifacts, diagnostics)
could contain this PII.

## Recommended Approach

1. Unset or scrub these variables in the forge entrypoint script
   (`entrypoint-forge-opencode.sh`).
2. Alternative: use anonymized placeholder values if Git needs identity to
   function inside the forge.
3. Verify in diagnostics that these vars are no longer visible.

## Triage decision — 2026-06-16 (linux, coord/critical-forge-proposal-triage-20260616)

**ACCEPTED. Confirmed real, current exposure.** Promoted to plan packet
`privacy/forge-git-identity-anonymization` (plan/index.yaml order 53).

Code evidence the host user's real identity is injected into the forge by
design (so this is not a stale diagnostics artifact):

- `crates/tillandsias-core/src/container_profile.rs:354-366,636-648` — defines
  `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL`
  as container env vars sourced from the configured git author name/email.
- `crates/tillandsias-headless/src/main.rs:4122-4125` — populates those four
  vars with the real `(name, email)` pair passed into the container launch.
- Forge entrypoint (`images/default/entrypoint-forge-opencode.sh`) does **not**
  scrub or override them (grep: zero matches).

**Design constraint for the implementer (why bare "unset" is wrong):** the
forge legitimately needs a git identity to author commits pushed to the enclave
mirror. Removing the vars would break attribution. The correct fix is the
proposal's option 2 — substitute an anonymized/forge identity (e.g.
`Tillandsias Forge <forge@localhost>` or a per-project pseudonymous identity)
at the `container_profile` / launch layer so the real host PII never enters the
container while commits still succeed. Decide whether a user-configurable real
identity should be opt-in. Validation: a diagnostics run shows no real-PII git
vars inside the forge AND an in-forge `git commit` still succeeds with the
substituted identity.

