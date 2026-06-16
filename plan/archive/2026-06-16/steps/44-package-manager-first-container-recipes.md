# Step 44 — Package-manager-first container recipes

- **Status**: completed
- **Owner host**: linux
- **Branch**: linux-next
- **Depends on**: none
- **Specs**: default-image, inference-container, user-runtime-lifecycle
- **Audit origin**: plan/issues/container-build-efficiency-telemetry-2026-06-08.md
- **Lease**: `lease-linux-package-recipes-20260608T185543Z`
- **Agent**: `linux-macuahuitl-codex-20260608T185543Z`

## Goal

Replace avoidable network installers and floating downloads in the forge and
sibling Containerfiles with Fedora 44 packages, while preserving the lean
CPU-only inference contract and using pinned, checksum-verified direct assets
only where no suitable package exists.

## Tasks

- [x] `container-recipes/fedora-package-migration`
  - Owned files: `images/default/Containerfile`,
    `images/inference/Containerfile`, related image-local checksum manifests.
  - Re-run Fedora 44 `dnf5 repoquery` for every proposed package.
  - Move verified tools to the existing `microdnf install` layer.
  - Remove both `curl | sh` / `curl | bash` installers.
  - Remove mutable `@latest`, `latest/VERSION`, and `releases/latest/download`
    references from image-producing inputs.
  - For tools without Fedora packages, pin versions and SHA-256 checksums or
    remove them when active specs do not justify them.
  - Measure the Fedora `ollama` RPM dependency/size impact before choosing it;
    retain a pinned CPU-only direct asset if the RPM violates the lean image
    contract.
- [x] Add static litmus coverage that rejects:
  - shell-piped network installers
  - floating `latest` inputs
  - unverified direct release assets
  - Fedora tools installed outside `microdnf` when a reviewed package mapping
    exists

## Acceptance evidence

- `rg` finds no `curl ... | sh`, `curl ... | bash`, `@latest`,
  `latest/VERSION`, or `releases/latest/download` in active Containerfiles.
- Every retained direct asset has a pinned version and verified checksum.
- A forge image build reaches the package/tool layers without compilation.
- Tool-presence tests cover every executable moved to DNF.
- Inference smoke proves `ollama` starts CPU-only and image size remains within
  the active bound.
- Targeted instant litmus and `./build.sh --check` pass.

## Fallback when blocked

If a package mapping breaks required versions or architecture support, complete
the static policy/litmus slice and record the exact package/version blocker in
the audit issue. Do not silently fall back to a floating installer.

## Evidence / handoff

- Implementation: `25cb5b3a`.
- Fedora and Fedora updates package resolution succeeded inside
  `fedora-minimal:44`; weak dependencies are disabled.
- RPM Fusion free/nonfree provided none of the missing reviewed tools; COPR
  candidates were unsuitable. The inventory is recorded in the audit issue.
- Forge image built successfully: 5,696 MB, 42 seconds on cached retry.
- Forge tool-presence smoke passed for all migrated and pinned executables.
- Inference image built successfully: 187 MB, 40 seconds; Ollama reports
  version 0.30.6.
- Unchanged forge and inference build invocations skipped in 0.90 and 0.53
  seconds respectively.
- Default-image instant litmus: 3/3 executed tests passed.
- Inference-container instant litmus: 2/2 executed tests passed.
- `./build.sh --check`: passed.
