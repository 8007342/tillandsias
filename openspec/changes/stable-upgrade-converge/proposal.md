# Proposal — stable-upgrade-converge

- **Builds on:** `hot-upgrade-live-stack` (1490-gttj: the binary handoff without
  stopping forges, ownership labels, adopt-on-start, `tillandsias --update`, the
  24-hour background check, the shared-stack skew policy, downgrade refusal) and
  `host-state-lifecycle` (the SOFT and HARD tiers, the Vault-store
  dispositions, the operator-data set). This change does not restate them. It
  adds what happens to every *reused* component after a stable release has been
  installed.
- **Design only.** No code lands with this change.

## Why

The operator's direction (2026-11-03), verbatim: "on every stable release that
gets auto installed we shall run full upgrades for any reused component, and
fully re-generate components that need to, or fail to upgrade cleanly, they get
thrown away and created from scratch: Idempotent and ephemeral".

Today a new release reaches a host only by a manual curl install. Even then
some components are silently reused at their old state:

- **The macOS guest OS** was Fedora 44's release-day image, never upgraded,
  until 1925-gupg (#801). It still upgrades only on a *fresh* provision: a VM
  that already exists keeps the packages it was provisioned with. On
  2026-11-01 the 6.19.10 kernel wedged a forge twice.
- **Shared enclave containers** (vault, proxy, nix-cache, catalog services) are
  reused by name after a binary swap. 1490-gttj measured that they keep
  running the old image.
- **Forge and enclave images** are rebuilt per version tag, but a failed or
  partial rebuild has no defined "throw away and rebuild" step.
- **The Windows distro** is adopted and only its headless binary is replaced.
- **Linux toolboxes** (`tillandsias-builder`, `tillandsias-nix`) are not ours
  by label and are never upgraded by us.

## What changes

- **ADDED** a *converge pass* that runs once after every stable install (and
  after `tillandsias --update`), after the 1490-gttj binary handoff. For each
  reused component it runs a full in-place upgrade. If the component needs
  regeneration, or the upgrade does not finish cleanly, it is thrown away and
  rebuilt from scratch, scoped to that one component.
- **ADDED** a fixed order of operations across Linux, macOS and Windows,
  including how running forges are treated (they finish on the old image and
  are never killed for an upgrade).
- **ADDED** a never-thrown-away set: the Vault store (governed by the existing
  dispositions), the model cache, projects and their mirrors, downloads, config,
  and the keyring items. A converge failure never escalates to a HARD reset on
  its own.
- **ADDED** rollback is fix-forward: no downgrade (1490-gttj already refuses
  one). A component that cannot converge is left rebuilt or marked failed,
  loudly, and the next release fixes it.

## Non-goals

- The updater itself, the handoff and the skew window. Those are in 1490-gttj.
- Upgrading anything the operator owns outside Tillandsias. That is
  open question 4 for the Linux toolboxes.
- Any new timer. The converge pass is triggered by a stable install, an event.
