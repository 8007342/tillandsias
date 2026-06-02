# Rootfs removal — switch all trays to Fedora's official WSL2 / cloud images

**Date opened**: 2026-06-02 (windows-bullo)
**Status**: decided, decomposition pending per host
**Decision-making operator**: bulloncito@gmail.com (user)
**Decision recorder**: windows-bullo-claude-opus (this agent)

trace:
- `plan/issues/tray-convergence-coordination.md` (original recipe-pin convergence — supersedes the `RECIPE_RELEASE_TAG = "v0.2.260526.1"` symmetric-pin discipline)
- `plan/issues/multi-host-integration-loop-2026-05-24.md` (the ~2h integration loop that will fan this out)
- `crates/tillandsias-vm-layer/src/materialize/mod.rs:1-18` (the Recipe materializer docblock that *already* describes the layer-cache model — this pivot honours that model, it doesn't fight it)
- `openspec/litmus-tests/litmus-recipe-release-tag-symmetric.yaml` (whose subject matter goes away with this pivot)
- `.github/workflows/recipe-publish.yml` (whose `tillandsias-rootfs-*` outputs become obsolete)

## What triggered the pivot

On 2026-06-02, after a clean WSL/podman reset on windows-bullo, the tray's
auto-provisioner stalled indefinitely at `Downloading Fedora rootfs 0 / 279MB
(0%)`. Diagnosis (see `crates/tillandsias-vm-layer/src/fetch.rs:106-209` —
`download_verified`) traced the silent hang to a `reqwest::Client::builder()`
construction with **no timeouts** (no `.connect_timeout`, no `.read_timeout`).
Manual `curl.exe -L` against the same GitHub release URL succeeded in ~30-60s,
so the artifact was fine; the in-tray client just half-died with the socket
open and no bytes arriving.

The fetch-timeout bug is real. But fixing it would only patch a symptom of a
deeper question the user raised: **why are we shipping a 280MB rootfs at all?**

## What we ship today

Three GitHub-release artifacts at tag `v0.2.260526.1` (cross-tray pinned in
`crates/tillandsias-windows-tray/src/wsl_lifecycle.rs:42` and
`crates/tillandsias-macos-tray/src/action_host.rs:1000`):

- `tillandsias-rootfs-x86_64.tar` (279 MB) — Windows tray imports via
  `wsl --import` (`crates/tillandsias-vm-layer/src/materialize/wsl.rs`).
- `tillandsias-rootfs-aarch64.tar` (audit, no first-class consumer).
- `tillandsias-rootfs-aarch64.img.xz` (74 MB compressed → ~8 GB sparse) —
  macOS tray boots via Virtualization.framework (`crates/tillandsias-vm-layer/src/materialize/macos.rs`,
  `crates/tillandsias-vm-layer/src/vz.rs`).

These tarballs/images are CI-pre-materialized recipe outputs: stock Fedora-44
base + podman + tools + (in the early integration tests) the
`tillandsias-headless` binary baked in. They were cut as a release-pinned
artifact in May 2026 to unblock cross-host provisioning while the in-VM
materializer was still being built.

## What the architecture always intended

`crates/tillandsias-vm-layer/src/materialize/mod.rs` is explicit:

> "The driver itself is platform-agnostic and runs on Linux CI hosts. Per-OS
> converters (`§3.7.1 macos::tar_to_vfr_img`, `§3.7.2 wsl::tar_to_wsl_import`)
> are sibling claims; this module exposes the rootfs `.tar` and trait
> extension points but does not implement the conversions itself."

The materializer is a Containerfile-style layer cache. The intent was that
the user's tray would either (a) materialize layers locally on first run, or
(b) pull a prebuilt rootfs cache from CI. We picked (b) as the v0.0.1 shortcut.

The pivot is: **remove the (b) shortcut. Bring up a stock Fedora WSL distro
on the user's host, install `tillandsias-headless` into it via a small
bootstrap, and let the recipe materializer run *inside* the VM if/when the
user runs skills that need additional layers** — which matches the docblock's
original design intent.

## The decision (recorded 2026-06-02)

Path B (from the architectural discussion):

**Use Fedora Project's official WSL2 image for the distro base.**

- Windows tray: `wsl --install -d FedoraLinux-44` (or `wsl --install --from-file`
  with a direct download) using Microsoft's WSL distribution registry, which
  points at:
  `https://download.fedoraproject.org/pub/fedora/linux/releases/44/Container/x86_64/images/Fedora-WSL-Base-44-1.7.x86_64.wsl`
  This is a Fedora-Project-signed `.wsl` file (Microsoft's new tar-based WSL
  distribution format, ~80MB compressed). Source of truth verified against
  `https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json`
  on 2026-06-02.
- macOS tray: pull Fedora's official aarch64 Cloud Base image
  (`Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2` or the raw.xz variant from
  `https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/`)
  → convert to raw for VZ.framework. Same source-of-truth principle.
- Both trays: bootstrap `tillandsias-headless` into the running distro via a
  small installer script (curl-fetch a single ELF binary + write a
  systemd-or-init unit). No baked-in binaries; the host tray installs the
  guest binary at runtime, like a container engine pulls images.

We accept the trade: **simpler, smaller, no GitHub-release rootfs to maintain,
no cross-tray release-tag pin, no Fedora-vs-our-fork drift**. We lose the
guarantee that all hosts run a byte-identical rootfs at a given pin — but
Fedora's own version pins (`-44-1.7` in the URL) give us coarse-grain
reproducibility, and the recipe materializer running in-VM gives us
fine-grain reproducibility for our own layers.

## Surface impact (what touches what)

### Source code (windows-next + osx-next can land in parallel after the linux-next decomposition packet lands)

- `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs`
  - Delete `RECIPE_RELEASE_TAG` const (line 42).
  - Delete `recipe_rootfs_artifact()` helper + its 4 unit tests (lines ~215, ~448, ~456, ~472).
  - New path: invoke `wsl --install -d FedoraLinux-44` OR download `.wsl` + `wsl --install --from-file` directly. Either gives us a registered distro named `FedoraLinux-44`.
  - Bootstrap script: copy a small `install-headless.sh` into the distro + `wsl -d FedoraLinux-44 -- bash install-headless.sh`. The script does `dnf install -y podman util-linux openssh-server` (idempotent) + curl-fetches the version-pinned `tillandsias-headless` binary into `~/.local/bin/` + writes the user-mode systemd unit.

- `crates/tillandsias-macos-tray/src/action_host.rs`
  - Delete `RECIPE_RELEASE_TAG` const (line 1000).
  - Refactor the boot path to fetch + convert the official Fedora aarch64 Cloud image instead of the pinned `.img.xz`.

- `crates/tillandsias-macos-tray/src/diagnose.rs`
  - Drop `release_tag: "v0.2.260526.1"` baseline (line 301). `release_tag` field in the diagnose JSON either disappears or reports "fedora-44" / the distro version.

- `crates/tillandsias-vm-layer/src/recipe/mod.rs`
  - The `artifact_url()` / `Manifest` test cases at lines 527-543 reference `v0.2.260526.1`. These belong to the *in-VM* recipe materialization machinery (which is staying, per the architecture-already-intended note above), but the *bootstrap* path that calls `recipe_rootfs_artifact()` is going away. Audit which uses are still load-bearing for in-VM layer materialization vs. obsolete-with-pivot.

- `images/vm/manifest.toml` — obsoleted (its only consumers are the symmetric-pin tests + the `recipe_rootfs_artifact` path).

- `crates/tillandsias-vm-layer/src/fetch.rs:106-209` (`download_verified`) — KEEP but still gets a progress-timeout fix as a small follow-up, because we'll still use it to download the official Fedora `.wsl` file. The reqwest-no-timeout bug is real and would bite us on Fedora's URL too if the server stalls. So that fix becomes step 1 of the windows-next slice.

### Tests / litmus / cheatsheets (delete or repurpose)

- `openspec/litmus-tests/litmus-recipe-release-tag-symmetric.yaml` — **delete**. Its subject (cross-tray pin symmetry) ceases to be a thing.
- `cheatsheets/runtime/windows-tray-diagnostics.md:153` + `images/default/.../windows-tray-diagnostics.md:86` — update `release_tag` field documentation (or remove if the field is dropped).
- `cheatsheets/runtime/macos-tray-diagnostics.md:92` + `images/default/.../macos-tray-diagnostics.md:92` — same.
- `cheatsheets/runtime/macos-pty-attach.md:201` — drop the "CI uploads `tillandsias-rootfs-aarch64.img`" line; the CI step is going away.
- All `plan/issues/windows-build-findings-*.md`, `plan/issues/macos-build-findings-*.md`, `plan/issues/osx-next-work-queue-2026-05-25.md` references — these are historical findings + don't need editing; new findings after the pivot will reference Fedora's URL instead.

### CI (the artifact pipeline goes away)

- `.github/workflows/recipe-publish.yml` — the workflow that builds + uploads `tillandsias-rootfs-x86_64.tar` / `-aarch64.tar` / `-aarch64.img` becomes obsolete for the rootfs path. The materializer test-execution side may still want CI (running `Recipe` end-to-end as a regression test), but the published-release-artifact step is gone.

### Diagnose schema (cross-tray)

- Windows-tray `DiagnoseReport`: `release_tag` + `manifest_pin_x86_64_tar` fields become "fedora-44-1.7" / N/A. JSON key count likely stays at 17 with field semantics changed, but document the semantic change in the cheatsheet. (Apply the 5-touchpoint drift-protection discipline.)
- macOS-tray `DiagnoseReport`: parallel change to its `release_tag` / `manifest_pin_aarch64_img`.

## Per-host work decomposition

Each host gets one packet pointing at this doc. The packets describe their
slice; this doc is the canonical decision record.

**Windows (`w11/wsl-distro-via-fedora-official-image`)** — replaces the
`wsl --import <our-tar>` path with `wsl --install -d FedoraLinux-44` or
direct `.wsl`-file download, deletes `RECIPE_RELEASE_TAG`, swaps to
curl-bootstrap. Also fixes the `fetch::download_verified` no-timeout bug as
step 1 because we'll still use it to download Fedora's `.wsl`. See
`plan/issues/windows-next-work-queue-2026-05-25.md` packet `w11/`.

**macOS (`m9/vz-boot-via-fedora-cloud-image`)** — replaces the `tar → .img →
VZ` path with `fetch Fedora cloud qcow2 → qemu-img convert to raw → VZ boot`.
Deletes `RECIPE_RELEASE_TAG`. See
`plan/issues/osx-next-work-queue-2026-05-25.md` packet `m9/`.

**Linux (`l10/decommission-rootfs-publish-workflow`)** — deletes the
`.github/workflows/recipe-publish.yml` rootfs-publishing steps + the
symmetric-pin litmus + `images/vm/manifest.toml`. Audits which `recipe/mod.rs`
test cases still serve the in-VM materializer vs. the now-obsolete pin path.
Coordinates the cross-host cheatsheet updates. See
`plan/issues/linux-next-work-queue-2026-05-25.md`.

## Open questions (resolve as the work proceeds)

1. **`.wsl` format support across WSL2 versions.** The `.wsl` file format is
   Microsoft's tar-based WSL distribution format introduced in 2024 with
   WSL2 2.4.4+. Older WSL2 installs (pre-2.4.4) won't recognise it via
   `wsl --install --from-file`. Options: gate on `wsl --version` and fall
   back to `wsl --import` (the `.wsl` is just a tar — can rename + import
   directly); or require a WSL2 minimum + surface a clear upgrade message in
   the diagnose report. The windows-tray `--diagnose` already reports
   `wsl_version`, so the gating is cheap.

2. **Fedora's signing model for the `.wsl` file.** Fedora signs its repodata
   with their GPG key, but the `.wsl` artifact itself is served over HTTPS
   from `download.fedoraproject.org` without a separate detached signature
   on the URL we surveyed. Acceptable for v0.0.1; for production we should
   fetch the matching `CHECKSUM` file from the same release directory + verify
   the SHA-256.

3. **`tillandsias-headless` distribution.** The curl-bootstrap needs an HTTPS
   URL serving the `headless` binary. Options: GitHub-release artifact at the
   tillandsias release tag (`tillandsias-headless-x86_64`); `install.tillandsias.org`
   GitHub Pages site that thin-redirects to GitHub releases; or a
   self-installer-style bootstrap that does `cargo install --git`. Simplest:
   GitHub releases (we already publish releases per the linux-next ledger;
   add the headless binary to the artifact set).

4. **macOS aarch64 image conversion toolchain.** qcow2 → raw conversion needs
   `qemu-img`. We currently ship `mkfs.ext4`/`parted`/`losetup` on the CI host
   for `materialize::macos::tar_to_vfr_img`. The new path either (a) ships
   `qemu-img` on the macOS host (Homebrew dependency), or (b) does the
   conversion on the Linux CI host and publishes a raw.xz alongside the
   qcow2 — sliding back to a CI-published-artifact model. Probably (a) is
   correct: macOS users mostly already have brew, and we can `brew install
   qemu` on first run if missing.

5. **In-VM materializer interaction.** Once a stock Fedora VM is running, when
   does the recipe materializer execute? Likely: on demand when a skill
   declares an additional container layer it needs. The materializer runs
   inside the VM (it's just buildah-style instructions); the host tray
   doesn't need to know. This matches the docblock's "platform-agnostic
   driver runs on Linux CI hosts" wording — except now the user's VM is the
   Linux host.

## Cross-host coordination notes

- This is a multi-host decision; the integration loop (~2h cadence) will
  merge each host's branch into linux-next as packets land.
- Per branch canon: this doc lives on **linux-next** (plan/-writes branch).
- Source-code commits go to each host's branch (windows-next, osx-next,
  linux-next). The 3 source-code slices are independent; they can land in any
  order after this decision-record doc.
- DO NOT delete `RECIPE_RELEASE_TAG` from one tray's source without the
  other's matching change merged — the symmetric-pin litmus would fail
  during the in-between window. Sequence: land the per-host const removals
  + delete the litmus YAML in the same linux-next coordination commit, OR
  add a `# pivot-in-progress` tombstone to the litmus before either tray
  pulls its const.

## Trace for future autonomous cycles

A `./claude-repeat --skill advance-work-from-plan` or `--skill loop` cycle
that lands on a host with a matching `w11/`, `m9/`, or `l10/` packet should
read this doc first (its path is recorded in the packet's `next_action`),
then execute the corresponding slice with the discipline this doc lays out.
The 5-touchpoint drift-protection discipline (impl + inline pin + cheatsheet
+ tray-diagnose.ps1 + install-windows.ps1 + litmus YAML) STILL APPLIES for
the diagnose-schema changes that come with the field-semantics shift.
