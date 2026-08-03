# Freshness audit — Podman mock and advisory ordering — 2026-08-03

- **Classification**: optimization
- **Status**: completed
- **Auditor**: `forge-tillandsias-codex-20260803t214004z`
- **Component**: `scripts/test-support/podman-mock.sh`
- **Disposition**: **updated**

The inventory reported 994 auditable components, 8 stamped, and 986 unstamped.
The actual oldest stamped component was `scripts/test-support/podman-mock.sh`
(16 days), but `scripts/local-ci.sh` sorted `freshness-stale:` records on field
2 (the path) rather than field 3 (age). The advisory therefore named a different
component as “top stalest” with total confidence. The sorter now uses
`sort -t' ' -k3,3nr`.

The mock remains live and useful; discard would remove the stateful container
fixtures used by shared-stack concurrency tests. Its stamp predated the order
443 stateful-container work, so the audit revalidated the current behavior and
updated the stamp.

Evidence:

- `bash -n scripts/test-support/podman-mock.sh` — PASS.
- A mock `exec tillandsias-vault cat /run/vault-handover/root.token` — refused
  as required; no fabricated Vault handover.
- `cargo test -q -p tillandsias-headless --bin tillandsias tests::list_cloud_projects_preflight_order`
  — 1/1 PASS.
- `litmus:podman-build-command-shape`, container naming, idiomatic routing,
  concurrency, shared-container cleanup, stateful shared-stack safety, and
  drain-vs-self-heal — PASS.
- `litmus:podman-path-availability` stopped on the known forge environment
  failure `podman unresponsive (>5s)`, already owned by
  `plan/issues/podman-sqlite-lock-zombie-cascade-2026-07-15.md`; it did not
  execute or contradict the mock component.
