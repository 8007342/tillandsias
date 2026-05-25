## Why

The current `vm-provisioning-lifecycle` spec requires the host shell to download a prebuilt `tillandsias-linux-x86_64` binary from GitHub Releases. This commits us to publishing a per-arch matrix of Linux binaries on every release (x86_64 for WSL2 / Intel Mac, aarch64 for Apple Silicon under VFR), turns the GitHub-release surface into an opaque trust boundary, and forces the question of Rosetta-in-Linux for Apple Silicon.

Owner stance (2026-05-24): **Tillandsias does not ship any Linux binaries**. Everything the in-VM runtime needs is described declaratively in a Containerfile-style recipe; the host materializes the rootfs at first run, per host arch, cached locally and reproducibly. Same mental model as the existing `images/forge/Containerfile`, extended to bake a bootable systemd + sshd + vsock-listener-capable VM rootfs.

This change replaces the binary-download path in `vm-provisioning-lifecycle` with a recipe-materialization path and introduces `images/vm/` as the recipe home.

## What Changes

- **BREAKING** Remove the requirement that vm-provisioning downloads `tillandsias-linux-x86_64` from GitHub Releases. The release pipeline no longer publishes a `tillandsias-linux-*` Linux binary as a separable artifact.
- **ADDED** `images/vm/Recipefile` — Containerfile-shaped recipe describing the in-VM rootfs (Fedora 44 base + systemd + podman + sshd + vsock-listener service + the in-VM `tillandsias-headless` built from source).
- **ADDED** `images/vm/manifest.toml` — pinned base-image digests per supported arch (`x86_64`, `aarch64`), expected SHA-256 of materialization outputs, recipe version stamp.
- **ADDED** `images/vm/bootstrap/` directory with executable shell scripts (`10-systemd.sh`, `20-tillandsias.sh`, `30-enclave.sh`) invoked as `RUN` steps during materialization. Mirrors existing per-service Containerfile convention.
- **ADDED** `RECIPE` directive vocabulary on top of standard Containerfile syntax: `RECIPE vsock-listen <port>`, `RECIPE entry <cmd>`, `RECIPE arch <list>` — interpreted by the materializer to wire up the VM-specific shape (systemd unit for vsock listener, root entrypoint, supported architectures).
- **ADDED** Recipe materializer in `tillandsias-vm-layer::recipe`: given `images/vm/Recipefile` + `images/vm/manifest.toml` + the host arch, produces a cached rootfs image at `~/Library/Application Support/tillandsias/vm-rootfs-<recipe-sha>-<arch>.{img,tar}` (or platform-equivalent paths).
- **ADDED** Per-arch materialization: the same recipe SHALL produce an x86_64 rootfs on WSL2 / Intel Mac hosts and an aarch64 rootfs on Apple Silicon hosts. No Rosetta involvement; the recipe selects the right `FROM` digest from `manifest.toml`.
- **ADDED** Layer-level caching: each `RUN` step's inputs (the previous layer hash + the command string + the script file contents) hash into a layer key; identical inputs hit the cache. Subsequent host installs reuse layers.
- **ADDED** Dual distribution path (D8, first-class): the DEFAULT install path fetches a CI-materialized, SHA-pinned **rootfs** (a reproducible recipe *output* — NOT a shipped `tillandsias-linux-*` binary) via `tillandsias-vm-layer::fetch::download_verified`, verifying against `manifest.toml`'s `[output] expected_rootfs_sha`. On-host materialization is the opt-in audit/dev path (`--materialize-local`). Default is **fetch** on Windows (avoids the buildah-in-WSL chicken-and-egg) and offered on macOS; Linux materializes only in CI + for dev (its tray is headless-native, no VM).
- **MODIFIED** `openspec/specs/vm-provisioning-lifecycle/spec.md` (delta): replace the binary-download requirements with recipe-materialization requirements; add the dual-path (fetch-default / materialize-local) requirement; preserve the condensed-status UX contract verbatim; update Cross-references.
- **MODIFIED** `Hello` capability `tillandsias-headless` advertises includes the recipe version it was built from, so the host shell can detect "in-VM headless out of sync with recipe" and trigger re-materialization.

## Capabilities

### New Capabilities

(none — refines an existing capability)

### Modified Capabilities

- `vm-provisioning-lifecycle`: replace binary-download requirements with recipe-materialization requirements; preserve condensed-status UX, always-drain shutdown, and SHA-verification contracts.

## Impact

- **BREAKING for release pipeline**: the `tillandsias-linux-x86_64` artifact is no longer published. The release workflow drops that job. Existing consumers (none in the wild — the macOS and Windows trays have not shipped yet) are unaffected.
- **Specs**: delta to `vm-provisioning-lifecycle`; cross-reference updates in `host-shell-architecture` and `macos-native-tray`.
- **New code**:
  - `tillandsias-vm-layer::recipe` module (parser for the extended Containerfile + manifest + layer hasher + cache resolver).
  - `tillandsias-vm-layer::materialize` module (driver that runs the recipe inside a throwaway containerized build env, captures the resulting rootfs, and emits a VM-bootable image).
- **New repo artifacts**:
  - `images/vm/Recipefile`
  - `images/vm/manifest.toml`
  - `images/vm/bootstrap/10-systemd.sh`
  - `images/vm/bootstrap/20-tillandsias.sh`
  - `images/vm/bootstrap/30-enclave.sh`
- **CI**: a new `recipe-smoke` job materializes the recipe on `ubuntu-latest` (x86_64) and `macos-latest` (aarch64), verifies the resulting rootfs boots, runs `tillandsias-headless --version`, and connects on vsock port 42420. Per D8 the job also records each rootfs's SHA-256 into `manifest.toml`'s `[output] expected_rootfs_sha.<arch>` and publishes the rootfs to a **content-addressed distribution surface** (OCI registry artifact or content-addressed URL) for the fetch-default path. This is NOT a `tillandsias-linux-*` binary upload — it is a recipe-derived, content-addressed rootfs whose trust root remains the in-tree recipe.
- **Build performance**: first-run materialization wall-clock estimate ~3 minutes (matches current cloud-init flow). Cached subsequent runs: <1 s (just resolve layer cache).
- **Storage**: rootfs caches grow to ~2.5 GB per arch per recipe-version on the user's host. `tillandsias-vm-layer::cache::gc` cleans entries older than 90 days or beyond a 5-entry-per-arch ceiling.
