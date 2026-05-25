## REMOVED Requirements

### Requirement: First-run provisioning downloads Fedora rootfs and tillandsias binary
**Reason**: Replaced by recipe-based materialization. Per owner stance 2026-05-24, Tillandsias does not ship any prebuilt Linux binaries; the in-VM environment is described declaratively in `images/vm/Recipefile` and materialized per-host-arch at first run.
**Migration**: The new `Requirement: First-run materializes VM rootfs from recipe` replaces this. The host-side code path that downloaded `tillandsias-linux-x86_64` from GitHub Releases SHALL be deleted; the release workflow SHALL drop that upload job.

## ADDED Requirements

### Requirement: First-run materializes VM rootfs from recipe

On a fresh host with no cached rootfs for the current recipe + host-arch, the host shell SHALL materialize the VM rootfs by interpreting `images/vm/Recipefile` against `images/vm/manifest.toml`. Materialization SHALL:

1. Resolve the host arch (`x86_64` on WSL2 / Intel Mac, `aarch64` on Apple Silicon).
2. Look up the corresponding `[[base]]` entry in `manifest.toml`; verify the pinned digest is reachable.
3. Pull the base image into a throwaway build environment (host's `buildah` or equivalent OCI builder).
4. Execute each `RUN`, `COPY`, and `RECIPE` directive in order; check layer cache before each.
5. Export the final rootfs as a `.tar` archive.
6. Convert to the platform-native VM image format (`.img` for VFR; importable tar for WSL2).
7. Write to the platform cache at `~/Library/Application Support/tillandsias/vm-rootfs-<recipe-sha>-<arch>.{img,tar}` (macOS), `%LOCALAPPDATA%\tillandsias\vm-rootfs-…` (Windows), or `~/.local/share/tillandsias/vm-rootfs-…` (Linux fake / dev).

The host SHALL NOT download a prebuilt, hand-built `tillandsias-*` Linux **binary** from GitHub Releases or any other source. The in-VM headless binary SHALL originate exclusively from `images/vm/bootstrap/20-tillandsias.sh`'s build step inside the recipe. That build step MAY be executed either on the user's host (local materialization) OR in CI, with the resulting recipe-derived rootfs fetched and SHA-verified on the host per the Requirement "First-run obtains the rootfs by fetch (default) or local materialization" below — a CI-materialized rootfs is a reproducible *output* of the recipe, content-addressed and recipe-version-stamped, and is NOT a "prebuilt binary" in the sense prohibited here.

@trace spec:vm-provisioning-lifecycle

#### Scenario: Apple Silicon host materializes aarch64 rootfs
- **WHEN** the macOS tray launches on Apple Silicon for the first time
- **THEN** the materializer SHALL select the `aarch64` `[[base]]` row from `manifest.toml`
- **AND** the resulting rootfs SHALL be aarch64-native (no Rosetta involved)
- **AND** the cached path SHALL include `-aarch64` in its filename

#### Scenario: WSL2 host materializes x86_64 rootfs
- **WHEN** the Windows tray launches on a WSL2 host for the first time
- **THEN** the materializer SHALL select the `x86_64` `[[base]]` row
- **AND** the resulting rootfs SHALL be x86_64-native
- **AND** the cached path SHALL include `-x86_64` in its filename

#### Scenario: Single recipe materializes both arches identically
- **WHEN** the same `Recipefile` is materialized on an x86_64 host and on an aarch64 host
- **THEN** the recipe-version SHA SHALL be identical (the source is one file)
- **AND** the two resulting rootfs blobs SHALL differ only in arch-dependent binaries
- **AND** the materializer SHALL log the recipe-version SHA for both runs

### Requirement: First-run obtains the rootfs by fetch (default) or local materialization

The host SHALL obtain the VM rootfs for the current recipe-version + host-arch by exactly one of two equivalent paths:

1. **Fetch (default).** Download the CI-materialized rootfs from the content-addressed distribution surface recorded in `images/vm/manifest.toml` and verify it against `[output] expected_rootfs_sha.<arch>` using a resumable, SHA-256-checked download. A checksum mismatch SHALL abort and fall back to local materialization (or surface a failure), never install an unverified rootfs.
2. **Local materialization (`--materialize-local`).** Run the full on-host materialization described in "First-run materializes VM rootfs from recipe".

Both paths SHALL yield a rootfs equivalent to running the recipe against the pinned base digests. The DEFAULT path SHALL be platform-appropriate: **fetch** on Windows (WSL2) and macOS (VFR); local materialization is always available as an explicit opt-in for audit/reproduction/dev. The Linux tray runs headless-native with no VM and SHALL NOT require either path at runtime; Linux performs materialization in CI (to produce `expected_rootfs_sha`) and on demand for recipe development.

A fetched rootfs SHALL be treated as recipe-derived (its `expected_rootfs_sha` and recipe-version stamp tie it to the in-tree recipe); it SHALL NOT be treated as, or substitute for, a prohibited prebuilt `tillandsias-*` binary.

@trace spec:vm-provisioning-lifecycle

#### Scenario: Windows host fetches the CI-materialized rootfs by default
- **WHEN** the Windows tray launches on a WSL2 host for the first time with no cached rootfs
- **THEN** the host SHALL download the rootfs from the content-addressed surface in `manifest.toml`
- **AND** SHALL verify it against `[output] expected_rootfs_sha.x86_64` before `wsl --import`
- **AND** SHALL NOT require buildah/podman inside WSL for the default path

#### Scenario: `--materialize-local` reproduces and bypasses fetch
- **WHEN** a contributor runs the tray with `--materialize-local`
- **THEN** the host SHALL run the full on-host materialization instead of fetching
- **AND** the resulting rootfs SHA SHALL be comparable to the pinned `expected_rootfs_sha.<arch>` for audit

#### Scenario: Checksum mismatch never installs an unverified rootfs
- **WHEN** a fetched rootfs's SHA-256 does not match the pinned `expected_rootfs_sha.<arch>`
- **THEN** the host SHALL NOT import or boot it
- **AND** SHALL either fall back to local materialization or surface a clear failure

### Requirement: Layer-level caching keyed on directive content

Each materialization step SHALL produce a layer whose cache key is the SHA-256 of (`previous_layer_content_sha || directive_text || copied_content_sha`). On subsequent materializations, the materializer SHALL check the cache before executing any step; identical cache key SHALL skip execution and reuse the cached layer's content.

The layer cache SHALL live at `<platform-cache-root>/recipe-cache/` and SHALL be garbage-collected per the rules in the Requirement: "Layer cache garbage collection" below.

@trace spec:vm-provisioning-lifecycle

#### Scenario: Re-materialization after unchanged source skips all steps
- **WHEN** the user runs the tray a second time without modifying any files in `images/vm/` or `crates/tillandsias-headless/`
- **THEN** every recipe step SHALL be a cache hit
- **AND** total materialization wall-clock SHALL be under 5 seconds (cache resolution only, no exec)

#### Scenario: Modifying a single bootstrap script invalidates only its layer onward
- **WHEN** the user edits `images/vm/bootstrap/30-enclave.sh` and re-runs the tray
- **THEN** the FROM, RUN, and COPY layers preceding `RUN /opt/bootstrap/30-enclave.sh` SHALL be cache hits
- **AND** the modified step + all downstream steps SHALL re-execute

### Requirement: `images/vm/Recipefile` defines the in-VM environment

The repository SHALL contain `images/vm/Recipefile` as the single declarative source for the in-VM environment. The file SHALL be a valid Containerfile augmented with the `RECIPE` directive vocabulary defined below, parseable by `tillandsias-vm-layer::recipe::parse`. The repository SHALL contain `images/vm/manifest.toml` with pinned base-image digests per supported architecture. The repository SHALL contain `images/vm/bootstrap/` with executable shell scripts invoked as recipe `RUN` steps.

@trace spec:vm-provisioning-lifecycle

#### Scenario: Recipefile is the single source of in-VM truth
- **WHEN** the user wants to know "what is inside the VM"
- **THEN** reading `images/vm/Recipefile` + `images/vm/bootstrap/*.sh` SHALL be exhaustive
- **AND** no other source (release notes, build script, external doc) is required

#### Scenario: Manifest pins base digests
- **WHEN** `images/vm/manifest.toml` is parsed
- **THEN** each `[[base]]` entry SHALL contain an `arch`, a `ref`, and a `digest` field
- **AND** the digest SHALL be a `sha256:...` immutable content-addressed identifier (not a tag)

### Requirement: `RECIPE` directive vocabulary

The Recipefile parser SHALL recognize three `RECIPE` directives in addition to standard Containerfile syntax:
- `RECIPE vsock-listen <port>` — at materialization time, install a systemd unit invoking `tillandsias-headless --listen-vsock <port>` on boot.
- `RECIPE entry <command>` — informational; declares the primary user-facing entrypoint. (Init remains systemd.)
- `RECIPE arch <arch1,arch2,...>` — comma-separated list of supported architectures; the materializer SHALL fail with a clear error if the host arch is not listed.

Unknown `RECIPE <verb>` directives SHALL cause the parser to fail with `unknown RECIPE verb: <verb>; valid: vsock-listen, entry, arch`.

@trace spec:vm-provisioning-lifecycle

#### Scenario: vsock-listen installs systemd unit
- **WHEN** the recipe contains `RECIPE vsock-listen 42420`
- **THEN** the materialized rootfs SHALL contain `/etc/systemd/system/tillandsias-headless.service`
- **AND** the unit's ExecStart SHALL include `--listen-vsock 42420`
- **AND** the unit SHALL be enabled to start on boot

#### Scenario: Arch mismatch fails clearly
- **WHEN** the recipe contains `RECIPE arch x86_64,aarch64` and the host is `riscv64`
- **THEN** the materializer SHALL exit non-zero with the message `host arch riscv64 not in recipe's supported set: x86_64, aarch64`

### Requirement: Layer cache garbage collection

The materializer SHALL garbage-collect layer cache entries that are older than 90 days OR that exceed a per-arch ceiling of 5 distinct recipe-version SHAs. GC SHALL run automatically at the end of every successful materialization. GC SHALL log removed entries with `spec = "vm-provisioning-lifecycle"`.

@trace spec:vm-provisioning-lifecycle

#### Scenario: 6th recipe version evicts the oldest
- **WHEN** five distinct aarch64 recipe-SHAs already have cache entries
- **AND** a 6th materialization completes successfully with a new recipe-SHA
- **THEN** the oldest (by mtime) of the previous five SHALL be removed
- **AND** the GC log SHALL record the eviction

#### Scenario: Stale entries beyond 90 days evict regardless of count
- **WHEN** a cache entry has mtime older than 90 days
- **THEN** the next materialization SHALL remove it
- **AND** the eviction SHALL log the age

### Requirement: Recipe-version SHA embedded in `Hello.capabilities`

The in-VM `tillandsias-headless` SHALL embed the recipe-version SHA it was built from as a capability string `"vm.recipe@<sha>"` in its `Hello` envelope. The host shell SHALL compare this against the recipe-version SHA of the on-disk `images/vm/Recipefile`; if they differ AND the host shell's structural compatibility check passes, the host shell SHALL inform the user that a re-materialization will incorporate the local recipe changes (via the condensed status surface).

@trace spec:vm-provisioning-lifecycle, spec:vsock-transport

#### Scenario: Stale in-VM headless after `git pull`
- **WHEN** the user pulls a Recipefile change and reconnects to the running VM
- **THEN** the host shell SHALL detect the SHA mismatch between in-VM `Hello.capabilities` and the on-disk recipe
- **AND** the menu status line SHALL transition to `🟡 VM recipe out of sync — re-materialize?`
- **AND** the user SHALL be able to trigger re-materialization from the menu

#### Scenario: Matching SHA is silent
- **WHEN** in-VM SHA equals on-disk recipe SHA
- **THEN** no status change SHALL occur

### Requirement: Release pipeline does not publish Linux binaries

The release workflow SHALL NOT publish any artifact of the form `tillandsias-linux-*` (binary or tarball). The host-shell trays (`tillandsias-macos-tray`, `tillandsias-windows-tray`) and the canonical Linux build (`tillandsias-headless` as part of the local-dev workflow) remain published artifacts; the in-VM headless that runs on non-Linux hosts SHALL be produced exclusively by recipe materialization on the user's host.

@trace spec:vm-provisioning-lifecycle, spec:ci-release

#### Scenario: Release workflow lacks Linux-binary upload step
- **WHEN** `.github/workflows/release.yml` is inspected
- **THEN** no job SHALL upload an asset matching `tillandsias-linux-*` to the GitHub release
- **AND** the only Linux artifact MAY be the canonical `tillandsias-headless` for direct Linux usage (separate from the host-shell flow)

#### Scenario: in-VM binary is never a downloaded prebuilt binary
- **WHEN** the in-VM `tillandsias-headless` arrives on the user's host by either D8 path
- **THEN** it SHALL have originated from `images/vm/bootstrap/20-tillandsias.sh`'s build step (executed on-host for local materialization, or in CI for the fetch path)
- **AND** the host SHALL NOT download a standalone prebuilt `tillandsias-*` binary asset
- **AND** any download on the fetch path SHALL be a recipe-derived, SHA-verified **rootfs** (content-addressed per D8), not a binary
