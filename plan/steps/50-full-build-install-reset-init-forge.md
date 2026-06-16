# Step 50 - Full Linux build/install/reset/init/forge smoke

- **Status**: completed
- **Owner host**: linux
- **Branch**: linux-next
- **Depends on**: local-smoke evidence-bundle and OpenCode prompt fixes
- **Specs**: release-smoke, forge-opencode-onboarding, tillandsias-vault

## Goal

Prove the current integrated `linux-next` head reaches a terminal local smoke
pass from source build through destructive substrate reset, pristine init, and
forge prompt execution.

## Tasks

- [x] Run the full destructive Linux build/install/reset/init/forge smoke.
- [x] Record terminal pass evidence, or file each new issue as a dated
  smoke-finding packet.

## Evidence / handoff

Podman wipe is expected and always acceptable on this host. Do not stop for
operator approval before resetting Podman during this smoke. The harness
default is `TILLANDSIAS_DESTRUCTIVE_RESET_OK=1`; setting it to `0` is the only
supported way for a non-smoke host to block the destructive reset.

Completed 2026-06-16 on integrated `linux-next` head.

- log_dir: `target/build-install-smoke-e2e/20260616T072454Z`
- build/install: pass; installed `Tillandsias v0.3.260616.1`
- evidence bundle: `target/convergence/evidence-bundle-20260616-073151.tar.gz`
  with 140 passed, 0 failed litmus checks
- Podman reset: pass; empty containers/images/volumes verified
- pristine init: pass; `init_exit=0`
- prompted forge: pass; `forge_exit=0`
- follow-up: forge diagnostics filed proposal backlog; critical/high proposal
  triage is tracked separately in `plan/issues/ACTIVE.md`
