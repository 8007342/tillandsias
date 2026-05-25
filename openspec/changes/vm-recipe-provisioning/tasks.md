## 1. Recipe authoring

- [ ] 1.1 Create `images/vm/Recipefile` with: `ARG TARGETARCH`, `FROM registry.fedoraproject.org/fedora:44@sha256:<pinned>`, `RUN dnf install -y systemd systemd-resolved openssh-server podman git rustup ...`, `COPY bootstrap/ /opt/bootstrap/`, three `RUN /opt/bootstrap/<N>-<name>.sh` invocations, and `RECIPE vsock-listen 42420`, `RECIPE entry /usr/local/bin/tillandsias-headless`, `RECIPE arch x86_64,aarch64`.
- [ ] 1.2 Create `images/vm/manifest.toml` with `recipe_version = 1`, two `[[base]]` rows (x86_64, aarch64) with pinned `sha256:` digests resolved from `registry.fedoraproject.org/fedora:44` via `skopeo inspect`, and an empty `[output] expected_rootfs_sha` table to be populated by CI on first successful run.
- [ ] 1.3 Create `images/vm/bootstrap/10-systemd.sh`: enables `systemd-networkd`, `systemd-resolved`, disables sshd in favor of vsock listener, configures kernel command line for fast boot (`quiet console=hvc0`).
- [ ] 1.4 Create `images/vm/bootstrap/20-tillandsias.sh`: clones the tillandsias workspace from the materialization context (bind-mounted at `/src`), runs `cargo install --path /src/crates/tillandsias-headless --target ${TARGETARCH}-unknown-linux-musl --root /usr/local`.
- [ ] 1.5 Create `images/vm/bootstrap/30-enclave.sh`: pre-pulls the OCI base images for the inner enclave (`tillandsias-proxy`, `tillandsias-git`, `tillandsias-forge`, `tillandsias-inference`) into the embedded podman storage so first user-action `--github-login` doesn't wait on container image pull.

## 2. `tillandsias-vm-layer::recipe` parser

- [x] 2.1 Create `crates/tillandsias-vm-layer/src/recipe/mod.rs` exposing `Recipe::parse(path: &Path) -> Result<Recipe>`.
- [x] 2.2 Parse standard Containerfile syntax (`FROM`, `ARG`, `RUN`, `COPY`, `ENV`, `WORKDIR`) — depend on an existing crate (e.g. `containerfile_parser`) if available; otherwise write a minimal directive lexer.
- [x] 2.3 Add `RECIPE` directive parsing: emit `RecipeDirective::VsockListen(u32)`, `RecipeDirective::Entry(String)`, `RecipeDirective::Arch(Vec<String>)`. Unknown verb → parse error.
- [x] 2.4 Add `Manifest::load(path: &Path) -> Result<Manifest>` that parses `manifest.toml` and exposes per-arch base digest lookup.
- [x] 2.5 Unit tests with a fixture recipe under `crates/tillandsias-vm-layer/tests/fixtures/recipe-basic/`.

## 2b. CI-fetch path artifacts (D6 amendment 2026-05-25)

- [ ] 2b.1 Update `images/vm/manifest.toml` `[output].expected_rootfs_sha` schema to key on `<arch>.<format>` (e.g. `"aarch64.tar"`, `"aarch64.img"`, `"x86_64.tar"`).
- [ ] 2b.2 Add `materialize::macos::tar_to_vfr_img(tar: &Path, dst: &Path) -> Result<()>`: parted/sgdisk on a sparse `.img`, mkfs.ext4 the root partition, mount loop, copy the `.tar` contents in, sync, detach. Works on Linux (CI) without macOS-specific tooling.
- [ ] 2b.3 Add a CI job `recipe-publish` (on tagged releases): materializes recipe → `.tar`, runs `tar_to_vfr_img` → `.img`, uploads both to the GitHub release with their SHA-256.
- [ ] 2b.4 Host-side `provision()` selects CI-fetch by default on macOS + Windows; falls back to local materialization if `--materialize-local` is set or if the GitHub release is unreachable. Reuses `tillandsias-vm-layer::fetch::download_verified` (the windows-next-added module).
- [ ] 2b.5 Add `--materialize-local` CLI flag to the tray binaries and document the trust model (recipe is canon; CI is cache; local is audit).

## 3. `tillandsias-vm-layer::materialize` driver

- [ ] 3.1 Create `crates/tillandsias-vm-layer/src/materialize/mod.rs` with `Materializer::run(recipe: &Recipe, manifest: &Manifest, host_arch: HostArch) -> Result<MaterializedRootfs>`.
- [ ] 3.2 Layer-hashing: compute `LayerKey = sha256(parent_layer_sha || directive_text || copied_content_sha)` per design D3.
- [ ] 3.3 Cache resolver: look up `LayerKey` under `<platform-cache-root>/recipe-cache/<key>.tar`; cache hit → skip exec, reuse content.
- [ ] 3.4 Cache miss exec: invoke `buildah` (or substitute) inside a throwaway working container, run the directive, snapshot the resulting filesystem to the cache.
- [ ] 3.5 After last directive: export the final rootfs as a `.tar` in the cache and emit `MaterializedRootfs::Tar`.
- [ ] 3.6 Per-arch sanity check: verify `host_arch` is listed in `RECIPE arch`; fail with the documented diagnostic if not.
- [ ] 3.7 Platform converters:
  - [ ] 3.7.1 `materialize::vfr::tar_to_raw_img(tar: &Path, dst: &Path)` — wraps in EFI System Partition + ext4 rootfs.
  - [ ] 3.7.2 `materialize::wsl::tar_to_wsl_import(tar: &Path) -> Result<()>` — wraps `wsl --import` invocation.
- [ ] 3.8 Recipe-trace ledger: write `<cache-root>/recipe-trace.jsonl` recording each layer (key, hit/miss, exec ms).

## 4. Cache GC

- [ ] 4.1 Implement `Cache::gc(arch: HostArch) -> GcReport` per spec: prune entries older than 90 days OR beyond the 5-per-arch ceiling (oldest mtime first).
- [ ] 4.2 Wire GC to run automatically at the end of every successful `Materializer::run`.
- [ ] 4.3 Add `tillandsias-vm-layer::cache::gc_now()` helper for manual triggering from CLI / tests.
- [ ] 4.4 Unit tests: fixture cache with 6 entries → 1 eviction; fixture cache with one 100-day-old entry → eviction.

## 5. Hello capability + recipe-SHA wiring

- [ ] 5.1 Compute the recipe-version SHA at `cargo install` time (env var injected into the `tillandsias-headless` binary via build-script).
- [ ] 5.2 `tillandsias-headless` emits `"vm.recipe@<sha>"` in its `Hello.capabilities`.
- [ ] 5.3 `tillandsias-host-shell` reads the on-disk recipe SHA at startup, compares to `HelloAck.capabilities`, and triggers the menu "VM recipe out of sync" status if they differ.

## 6. Spec sync + release workflow edit

- [ ] 6.1 Run `/opsx:sync vm-recipe-provisioning` to merge the delta into `openspec/specs/vm-provisioning-lifecycle/spec.md`.
- [ ] 6.2 Regenerate `openspec/specs/vm-provisioning-lifecycle/TRACES.md`.
- [ ] 6.3 Edit `.github/workflows/release.yml`: remove any job that uploads `tillandsias-linux-x86_64` or `tillandsias-linux-aarch64` as a release asset.
- [ ] 6.4 Add a `recipe-smoke` job to `.github/workflows/ci.yml` (or release.yml): runs on `ubuntu-latest` (x86_64) and `macos-latest` (aarch64), materializes the recipe, boots the VM, asserts `tillandsias-headless --version` returns and vsock port 42420 is listening.
- [ ] 6.5 On first successful `recipe-smoke` run, capture the rootfs SHA-256 and write it to `images/vm/manifest.toml` under `[output] expected_rootfs_sha.<arch>`; commit.

## 7. Cross-reference updates

- [ ] 7.1 Edit `openspec/specs/host-shell-architecture/spec.md` to reference recipe materialization (replace any text mentioning binary download).
- [ ] 7.2 Edit `openspec/specs/macos-native-tray/spec.md` cross-references list to reflect the new flow.
- [ ] 7.3 Edit `crates/tillandsias-headless/Cargo.toml` build-script to compute recipe SHA at build time when materializing inside the recipe.

## 8. Verify

- [ ] 8.1 Run `openspec validate vm-recipe-provisioning` — expect "valid".
- [ ] 8.2 Local materialization on a Linux dev host: `cargo run -p tillandsias-vm-layer --bin materialize-cli -- images/vm/Recipefile images/vm/manifest.toml` produces a valid rootfs.tar.
- [ ] 8.3 Local materialization on macOS dev host: same command produces an aarch64 rootfs.tar; cached on second run (<5 s).
- [ ] 8.4 Convert to VFR raw image; boot under `objc2-virtualization`; verify systemd init, vsock listener on 42420, `tillandsias-headless --version` works.
- [ ] 8.5 Convert to WSL2 import tar; `wsl --import`; verify the same inside the WSL distro.
- [ ] 8.6 CI `recipe-smoke` job green for both arches.

## 9. Archive

- [ ] 9.1 Once verified, run `/opsx:archive vm-recipe-provisioning`.
