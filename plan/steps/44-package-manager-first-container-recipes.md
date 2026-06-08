# Step 44 — Package-manager-first container recipes

- **Status**: claimed
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

- [ ] `container-recipes/fedora-package-migration`
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
- [ ] Add static litmus coverage that rejects:
  - shell-piped network installers
  - floating `latest` inputs
  - unverified direct release assets
  - Fedora tools installed outside `microdnf` when a reviewed package mapping
    exists

## Next action

Run:

```bash
dnf5 repoquery --info rustup rust cargo clippy rustfmt rust-analyzer \
  cargo-deny delve shfmt ollama ruff poetry pipx uv black pylint \
  yamllint python3-mypy python3-pytest pnpm yarnpkg
```

Then produce a before/after inventory table keyed by executable and source.

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

Research baseline and package matrix:
`plan/issues/container-build-efficiency-telemetry-2026-06-08.md`.
