# macOS: forge-base built in-guest is the VM-setup fragility + is wrong-arch — 2026-07-05

- class: enhancement (forge image) — macOS evidence for the container creation-time split
- filed: 2026-07-05
- owner: linux (image owner) — macOS host filed the evidence
- status: ready
- pickup_role: linux
- depends_on: forge-firstrun-tool-migration-2026-07-04.md,
  forge-image-creation-vs-firstrun-split-research-2026-07-04.md,
  forge-persistent-tool-cache-mount-2026-07-04.md (order 179, DONE)
- trace: spec:default-image, spec:forge-cache-dual
- host-context: macOS Apple Silicon (Darwin arm64), Virtualization.framework
  Fedora 44 guest, tray v0.3.260704.1 (osx-next @ 9614d32f, linux-next @ 7ab86309 merged in)

## Why this is filed from macOS

The operator reported the macOS tray "never finished setting up the VM" and asked
that the macOS tray benefit from the container creation-time split
(CREATION_TIME / FIRST_RUN / EVERY_LAUNCH). This packet records the macOS-side
ground-truth evidence so the linux-owned migration
(`forge-firstrun-tool-migration`) closes the macOS case too, not just x86_64 Linux.

## Ground-truth evidence (this host, this cycle)

Control wire is healthy — `--exec-guest` boots the VZ VM and reaches Podman in the
guest E2E (`podman run hello-world` → `{"status":"ok","exit_code":0}`). The problem
is **forge image creation**, not the transport:

1. **`localhost/tillandsias-forge-base` is ABSENT in the guest.** `podman image
   exists localhost/tillandsias-forge-base` → NO. Present images are the
   registry-pulled service images (`tillandsias-vault`, `-proxy`, `-git`,
   `rust:alpine`, `hashicorp/vault`) — forge-base is not among them.
2. **forge-base is BUILT at runtime in the guest, not pulled.**
   `tillandsias-headless/src/main.rs:1560` calls `ensure_image_exists(root,
   "forge-base", …)`; `tillandsias-core/src/image_builder.rs:308` resolves
   `forge-base` → `images/default/Containerfile.base`; `scripts/build-image.sh`
   runs `podman build -f Containerfile.base` **with no `--platform`**. So on a
   cold macOS guest, first forge launch triggers a full in-guest `podman build`.
3. **That build runs a long, fragile CREATION-time curl/tar chain.**
   `Containerfile.base` L60–L124 hardcodes `ARG …_VERSION` + `ARG …_SHA256` for
   ~15 cargo tools plus actionlint/vale/wasmtime/dart and a sequential
   `install_archive` (curl → sha256 → tar) per tool, all over the forge egress
   proxy. Any one stalled fetch hangs the whole `podman build` → **the observed
   "stuck initializing the VM".** This is the exact fragility the split removes by
   reducing CREATION to the `microdnf` base layer and moving these tools to an
   idempotent FIRST_RUN install into the persistent cache (order 179 volume).
4. **Wrong-architecture tools (correctness bug, macOS-specific).** The guest is
   **aarch64** (`uname -m` = aarch64; Podman `OS/Arch: linux/arm64`). Every
   `install_archive` URL is hardcoded **`x86_64-unknown-linux-gnu`** /
   `x86_64-linux` / `linux_amd64`, with no arch resolution in `Containerfile.base`
   or `lib-common.sh` and no `--platform` on the build. `sha256sum -c` passes (it
   is the correct checksum for the x86_64 tarball) and `tar -xzf` succeeds, so the
   build *completes* but bakes **non-executable x86_64 binaries** into an aarch64
   image (exec-format error at use). forge-base has simply never successfully
   materialized usable dev tools on this host.
5. **Podman volume-lock errors during guest ops** (new, see sibling finding):
   `freeing lock for volume <id>: no such file or directory` on multiple stale
   volume ids — surfaced while listing images. Likely interaction with the order
   179 named tool-cache volume; filed separately as
   `podman-stale-volume-locks-2026-07-05.md`.
6. **Minor UX:** `--opencode <path>` rejects a path outside the expected project
   root with `Error: Project not found: <path>` before any forge work — expected,
   but the message should name the expected location.

## What the migration must add for macOS (the gap)

`forge-firstrun-tool-migration` and `forge-image-creation-vs-firstrun-split-research`
are written from an x86_64-Linux vantage and **keep the x86_64 URLs**. For macOS
(and any aarch64 host) the migration MUST be **arch-aware**: the reusable
`install_prebuilt <name> <latest-resolver>` helper resolves the asset for
`$(uname -m)` (x86_64 / aarch64) at FIRST_RUN, not a hardcoded x86_64 URL. This is
additive to the migration's existing "resolve LATEST version" requirement — resolve
LATEST **for the running arch**. Without it, moving the same x86_64 URLs to
first-run just relocates the wrong-arch bug.

## Verifiable closure (macOS lens)

- On a cold macOS (Apple Silicon) guest, `Containerfile.base` build is
  `microdnf`-only (no curl/tar tool chain) → forge-base materializes fast and does
  not hang VM setup. (measurable: base build wall-time drops; no per-tool curl at
  build.)
- First forge launch installs the dev tools at FIRST_RUN into the persistent cache
  as **aarch64** binaries that execute (`cargo-nextest --version` etc. succeed in
  the guest); second launch is a no-op (idempotency litmus).
- No `x86_64` asset is fetched on an aarch64 guest (grep the first-run install log).
- Cross-link resolved: `forge-firstrun-tool-migration` references arch-awareness.

## Handoff

Linux owns `images/default/Containerfile.base` + `lib-common.sh` + the
`install_prebuilt` helper; this packet is the macOS acceptance evidence. The macOS
tray needs **no tray-side code change** to benefit — it triggers the shared
in-guest build/first-run path — so the fix lands linux-side and osx re-verifies via
`--opencode`/`--exec-guest` once the migration ships.

## LINUX RESOLUTION 2026-07-05 (order 188, slice 1 of 180) — cargo-tools group

Linux implemented the arch-aware FIRST_RUN migration for the cargo-tools group:

- `images/default/lib-common.sh`: new `_forge_uname_arch` (x86_64|aarch64 from
  `uname -m`), `install_prebuilt <bin> <url>` (idempotent, fail-soft, `curl
  --max-time` so a stalled fetch can never hang launch, extracts to
  `$CARGO_HOME/bin`), and `ensure_forge_prebuilt_tools` (15 cargo tools, arch token
  substituted into every URL — NO hardcoded x86_64). Installs into the order-179
  persistent named-volume cache.
- The 4 forge entrypoints call `ensure_forge_prebuilt_tools &` (backgrounded — never
  blocks the agent launch).
- `images/default/Containerfile.base`: the cargo-tools `install_archive` block +
  cargo-nextest + all their `ARG _VERSION/_SHA256` constants REMOVED (creation is
  much shorter now). Also moved the Antigravity `agy` install out of the Containerfile
  (it was a pipe-to-shell) into an every-launch install-if-missing in its entrypoint.
- Verified on x86_64: `install_prebuilt cargo-nextest` downloads + extracts +
  `cargo-nextest --version` succeeds; second call is an instant no-op (idempotent).
  All aarch64 asset URLs pre-verified to exist (HTTP 200). Policy-compliant: direct
  release-asset CDN URLs, NO GitHub API, NO cargo install/binstall.
- Litmus: `forge-firstrun-prebuilt-tools-arch-shape` (new) + updated the stale
  `default-image-containerfile-shape` STEPs 7-8 to the first-run structure. default-
  image litmus suite 100%.

**Still baked (next slice, order 180 continuation):** actionlint / vale / wasmtime /
dart remain build-time x86_64 in Containerfile.base — same arch treatment needed to
reach the "microdnf-only creation" end state. cargo tool VERSIONS are a centralized
pinned floor in lib-common; de-hardcoding to `releases/latest` (web redirect, not the
API) is the follow-up.

**macOS acceptance (please re-verify on a cold Apple-Silicon guest):** forge-base
build no longer runs the cargo curl/tar chain (shorter, should not hang); first
`--opencode`/`--codex` launch background-installs the cargo tools as aarch64 binaries
into the persistent cache (`cargo-nextest --version` etc. should succeed); no x86_64
cargo asset fetched (grep the trace log for `installed prebuilt … (aarch64)`).
