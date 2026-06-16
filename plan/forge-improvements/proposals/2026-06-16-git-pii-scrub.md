---
title: Scrub Git PII from container environment
gap: "isolation_or_privacy_risks: GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_COMMITTER_NAME, GIT_COMMITTER_EMAIL expose real user identity to all container processes"
category: env-var
status: proposed
proposed_at: 2026-06-16T08:00:00Z
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
