---
title: Install Flutter SDK
gap: "missing_tools: flutter; Dart SDK installed + flutter.md instruction exists, but flutter binary absent"
category: sdk
status: proposed
proposed_at: 2026-06-16T08:30:00Z
changes:
  - file: images/default/Containerfile.base
    description: |
      Download and install Flutter SDK tarball to /opt/flutter, export
      FLUTTER_ROOT and prepend /opt/flutter/bin to PATH. Image-size
      impact ~1GB — orchestrator should gate at size budget.
approval_required: orchestrator
---

## Gap

The Dart SDK (3.12.1) is installed, `FLUTTER_ROOT=/opt/flutter` is
preconfigured in the runtime Containerfile env, and agent instructions
include `flutter.md`, but the flutter binary itself is absent — the
Flutter frontend toolchain is incomplete.

## Evidence

From `plan/diagnostics/diagnostics_20260616T081755Z-summary.md`:

- `proposed_enhancements` includes:
  `{"tool": "flutter", "ecosystem": "dart", "why": "Dart SDK 3.12.1 is installed and agent instructions include flutter.md, but flutter binary is absent — adding it completes the Flutter toolchain for Tillandsias frontend work."}`

- Previously captured on the curated-toolchain-backlog (2026-05-29) as
  `deferred` status due to ~1GB image-size impact.

## Privacy / Isolation Assessment

- Flutter SDK installs as a tarball extracted to `/opt/flutter` at image
  build time — same mechanism as the existing Dart SDK install.
- `flutter doctor` needs network on first run, governed by the existing
  proxy ACL (same envelope as `cargo` fetching crates).
- No new credentials, mounts, or privileges required.
- ~1GB image-size increase — orchestrator should approve or reaffirm
  the deferred status with rationale.

## Re-proposal note

This gap was previously filed in `2026-05-28-additional-tools-from-summary.md`
(status: implemented) but only Dart SDK was added. The curated backlog
(2026-05-29) set flutter to `deferred` for size. If the orchestrator
still considers the 1GB cost too high, set this proposal to `deferred`
or `rejected` with rationale.
