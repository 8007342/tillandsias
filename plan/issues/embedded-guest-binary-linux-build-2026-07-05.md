# Linux build plan: two-arch static guest binary the macOS/Windows trays embed — 2026-07-05

- class: packaging+build
- filed: 2026-07-05
- owner: linux
- pickup_role: linux (step 1); macos + windows (steps 2/3)
- status: done
- related:
  - plan/issues/embedded-guest-binary-packaging-research-2026-07-04.md (osx-filed)
  - plan/issues/embedded-guest-binary-packaging-implementation-2026-07-04.md (osx-filed)

## The linux-owned question

macOS/Windows trays boot an in-VM Linux "headless" binary
(`tillandsias-headless`, feature `listen-vsock`, bin name `tillandsias`) that
must match the host wrapper's source revision — version skew breaks the
control-wire handshake (the secure responder "early eof"). The operator's
chosen shape: the host app **embeds** the cross-compiled Linux guest binary
(both x86_64 and aarch64) and injects it into the VM, exactly like the tray
embeds Containerfiles, so local smokes never depend on Wi-Fi or a release.

macOS filed the packaging/implementation packets. The **linux-owned** slice:
*how does Linux produce a stable, cross-compilable guest binary artifact the
trays can embed?* This document answers it from the tree, not from guesses.

## Q1 — Cross-compile feasibility: **YES, already implemented**

`tillandsias-headless --features listen-vsock` already cross-compiles to BOTH
`x86_64-unknown-linux-musl` and `aarch64-unknown-linux-musl` as static,
VM-injectable binaries. This is not aspirational — the Nix flake ships both
packages today and the release pipeline already builds + validates them.

Evidence (all in-tree):

| Fact | Location |
|---|---|
| `rustToolchain` carries both musl targets | `flake.nix:25` (`targets = [ "x86_64-unknown-linux-musl" "aarch64-unknown-linux-musl" ]`) |
| Package `tillandsias-headless-x86_64-musl` builds `-p tillandsias-headless --bin tillandsias --features listen-vsock` for x86_64-musl | `flake.nix:73-86` |
| Package `tillandsias-headless-aarch64-musl` builds the same for aarch64-musl | `flake.nix:88-115` |
| aarch64 C cross-toolchain from `pkgsCross.aarch64-multiplatform-musl` (ring's build.rs + linker) — no external download | `flake.nix:48-50, 93-114` |
| TLS is rustls/ring (no OpenSSL) → cross only needs the C compiler for ring | `flake.nix:34-35` |
| x86_64-musl static flags `+crt-static`, `relocation-model=static` | `.cargo/config.toml` (`[target.x86_64-unknown-linux-musl]`) |
| `listen-vsock = ["tokio-vsock", "tillandsias-control-wire/vsock"]`; bin `tillandsias` | `crates/tillandsias-headless/Cargo.toml:84, 10-12` |
| **Both arches already built + validated in release** | `.github/workflows/release.yml:81-82, 126-127, 136-137` |
| Same two `nix build` commands warmed in cache CI + preflight | `.github/workflows/nix-cache-warm.yml:49-50`; `scripts/release-preflight-local.sh:97-98` |

What's needed to cross-compile: **only Nix** (`nix build`). The flake is
hermetic — crane + `rust-overlay` supply the edition-2024 toolchain, and
`pkgsCross` supplies the aarch64 musl C compiler, so no host `rustup`, no
`cross` container, no `musl.cc` download. (`build.sh --install` uses a
`rustup`-managed x86_64-musl `cargo build` — but that is the **host** wrapper
`--features tray`, x86_64 only, and needs a C cross-toolchain it doesn't have
for aarch64; see `build.sh:440-547`. For **both** guest arches reproducibly,
Nix is the canonical path — which is exactly why release.yml uses it and why
the macOS host, lacking rustup/cross, cannot produce these itself.)

Staticness is currently asserted only loosely for the guest binaries:
release.yml greps `file` for the **arch** of each headless binary
(`release.yml:136-137`) but greps `"statically linked"` only for the host
binary (`release.yml:135`). Hardening this into a guest-binary litmus is part
of Q4.

## Q2 — The exact build command, artifact, naming, and arch selector

### Build (linux, reproducible)

```bash
nix build .#tillandsias-headless-x86_64-musl  --out-link result-hx
nix build .#tillandsias-headless-aarch64-musl --out-link result-ha
```

### Artifact paths and names

Each Nix package outputs `<store>/bin/tillandsias`. Stage under the canonical
release names (identical to `release.yml:126-127`, so trays and releases agree):

| Arch | Nix output | Canonical embed name |
|---|---|---|
| x86_64 | `result-hx/bin/tillandsias` | `tillandsias-headless-x86_64-unknown-linux-musl` |
| aarch64 | `result-ha/bin/tillandsias` | `tillandsias-headless-aarch64-unknown-linux-musl` |

Proposed linux helper (new, linux-owned; mirrors `scripts/build-sidecar.sh`
which already stages a cross-compiled musl binary into `target-musl/`):
`scripts/build-guest-binaries.sh` runs the two `nix build`s, copies the outputs
to a stable staging dir (e.g. `target-guest/` — a build output, **not**
git-committed; these are large arch-specific ELFs), and runs the Q4 assertions.
The tray build scripts consume that staging dir.

Recommended embed layout (macOS/Windows own the exact placement):
- macOS `.app`: `Contents/Resources/guest/tillandsias-headless-<arch>-unknown-linux-musl` (bundle already has `Contents/Resources/`, `scripts/build-macos-tray.sh:63,81,85`; ad-hoc `codesign --deep --strict` at `:92-99` — a Linux ELF is a data resource, not a Mach-O, so it needs no signature of its own, only to sit inside the sealed bundle).
- Windows installer: alongside the tray exe payload.

### Where the host-arch selector picks x86_64 vs aarch64 at inject time

The injected binary is addressed by `ProvisionManifest.tillandsias_binary`
(`crates/tillandsias-vm-layer/src/lib.rs:92`), a **host-local path**. The host
already reads it and pushes it into the guest:
`crates/tillandsias-vm-layer/src/wsl.rs:209-260` (`provision` checks the path
exists, then `tokio::fs::read(&manifest.tillandsias_binary)` and pipes the
bytes into the WSL2 distro); macOS builds its manifest via
`vz.rs:802 from_manifest`.

Guest arch == host CPU arch, because these are native-virtualization VMs (VZ
runs an aarch64 guest on Apple Silicon / x86_64 on Intel Macs; WSL2 runs the
host CPU arch — not cross-arch emulation). So the selector is **host arch at
inject time**: the host picks `std::env::consts::ARCH` (x86_64 vs aarch64),
resolves the matching embedded asset, and points `tillandsias_binary` at it.

Contrast the **path being replaced**: today the guest arch is chosen *inside
the VM* by `uname -m` against `releases/latest`. Both `vz.rs:446` (macOS) and
`wsl_lifecycle.rs:332` (Windows) write a `fetch-headless.sh` +
`tillandsias-headless-fetch.service` systemd unit that runs
`curl … releases/latest/download/tillandsias-headless-${ARCH}-unknown-linux-musl`.
That is the Wi-Fi dependency and the version-skew hazard (the guest fetches
`latest`, never the wrapper's own source rev).

## Q3 — Staged plan (with role split)

### Step 1 — LINUX-owned: produce the two-arch guest artifacts reproducibly
- Add `scripts/build-guest-binaries.sh` that runs the two `nix build`s and
  stages `tillandsias-headless-{x86_64,aarch64}-unknown-linux-musl` into a
  build-output dir the tray builds consume. Ship the naming contract (Q2) and
  the version-stamp + static assertions (Q4). Do **not** commit the binaries.
- Publish the **contract** the trays depend on: names, staging path, and the
  guarantee that the guest binary embeds the same `VERSION` as the host wrapper
  (both `include_str!("../../../VERSION")` from one tree → matching
  `--version`). Optional linux enhancement: extend `build.rs` to also stamp a
  git short-sha (no `vergen` today; `build.rs` embeds runtime assets only) for
  commit-granular skew detection — a code change, tracked separately.
- Deliverable of this step: this document + the helper script + litmus.

### Step 2 — MACOS + WINDOWS-owned: embed + select (their scope)
- macOS: `scripts/build-macos-tray.sh` copies both staged binaries into
  `Contents/Resources/guest/`; the launcher selects by host arch and sets
  `ProvisionManifest.tillandsias_binary` to the embedded path.
- Windows: `scripts/build-windows-tray.ps1` / installer stages both; same
  host-arch selection into the manifest.
- The operator accepts embedding both arches; injecting only the host-arch
  match keeps the VM lean while the bundle stays portable.
- (Covered by the osx implementation packet
  `embedded-guest-binary-packaging-implementation-2026-07-04.md`.)

### Step 3 — MACOS (vz.rs) + WINDOWS (wsl_lifecycle.rs)-owned: drop the network fetch
- Remove/neutralize the `tillandsias-headless-fetch.service` + `fetch-headless.sh`
  writes and make `tillandsias-headless.service` depend on the host-injected
  binary instead of the fetch unit (`vz.rs:446-521` is macOS-owned;
  `wsl_lifecycle.rs:332-481` is windows-owned — each platform edits its own).
- Keep a transitional network fallback only when the embedded asset is absent
  (per the osx implementation packet), then delete it once both trays ship.

**Ownership summary:** Step 1 = linux. Step 2 = macos + windows. Step 3 = macos
(vz.rs) + windows (wsl_lifecycle.rs). Linux never edits the tray/vm-layer code;
it produces the artifact + contract + litmus the other hosts consume.

## Q4 — Verifiable litmus idea

A `verify-guest-binaries` check (a `scripts/build-guest-binaries.sh --verify`
mode, or a `scripts/run-litmus-test.sh embedded-guest-binary` case) that, after
the two `nix build`s:

1. **Both build**: both `result-hx/bin/tillandsias` and `result-ha/bin/tillandsias` exist and are executable.
2. **Both static + correct arch** (harden past release.yml, which only greps arch for the guest):
   - `file result-hx/bin/tillandsias` → matches `x86-64` **and** `statically linked`.
   - `file result-ha/bin/tillandsias` → matches `aarch64` **and** `statically linked`.
3. **Version-stamp match = same source rev**: the x86_64 guest binary runs on
   the x86_64 CI host, so
   - `result-hx/bin/tillandsias --version` == `Tillandsias v$(tr -d '\n' < VERSION)`,
     and both guest builds came from the same `craneSrc` tree as the host
     wrapper (`tillandsias-x86_64-musl`), so the host wrapper's `--version`
     matches too. (`--version` prints `Tillandsias v{VERSION}` —
     `crates/tillandsias-headless/src/main.rs:81,98`.) The aarch64 binary can't
     run on x86_64 CI, so assert its stamp by embedded-string check
     (`strings result-ha/bin/tillandsias | grep -qF "$(tr -d '\n' < VERSION)"`)
     until an aarch64 runner exists.

Pass criterion: both guest binaries build, are static for their arch, and carry
the same `VERSION` stamp as the host wrapper — i.e. an embedded guest can never
be from a different source rev than the wrapper that ships it. Gate it in a
Nix-capable phase (build may be slow on a cache miss; rely on the warmed Nix
cache, `nix-cache-warm.yml`).

## Grounding index (file:line)

- flake guest packages + cross toolchain: `flake.nix:25, 34-35, 48-50, 73-115, 205-207`
- x86_64-musl static flags: `.cargo/config.toml`
- listen-vsock feature + bin: `crates/tillandsias-headless/Cargo.toml:10-12, 84`
- release build/name/validate: `.github/workflows/release.yml:81-82, 126-127, 135-137`
- cache-warm + preflight: `.github/workflows/nix-cache-warm.yml:49-50`; `scripts/release-preflight-local.sh:97-98`
- inject manifest + host read: `crates/tillandsias-vm-layer/src/lib.rs:88-100`; `crates/tillandsias-vm-layer/src/wsl.rs:209-260`; `crates/tillandsias-vm-layer/src/vz.rs:802`
- in-VM fetch to drop: `crates/tillandsias-vm-layer/src/vz.rs:446-521`; `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs:332-481`
- version stamp: `crates/tillandsias-headless/src/main.rs:81, 98`; `crates/tillandsias-headless/build.rs` (no git-sha stamp today)
- staging precedent: `scripts/build-sidecar.sh`; macOS bundle Resources: `scripts/build-macos-tray.sh:63,81,85,92-99`

## Exit criteria

- Cross-compile feasibility answered from the tree (YES; Nix-only) with evidence.
- Exact build command, artifact paths, canonical names, and the host-arch
  inject-time selector documented.
- Staged plan with per-step linux/macos/windows ownership.
- A litmus that proves both guest binaries build, are static per arch, and
  version-stamp-match the host wrapper (no cross-rev embed possible).

## macOS blocker ping 2026-07-05T18:53Z

`/meta-orchestration` on macOS selected order 193 as the top macOS implementation
packet, then stopped before code work because the macOS checkout is dirty and
this Linux-owned artifact contract is still unresolved.

Linux should pick this packet before expecting macOS packaged cold-boot evidence.
The smallest Linux slice is:

1. add `scripts/build-guest-binaries.sh`;
2. stage `tillandsias-headless-x86_64-unknown-linux-musl` and
   `tillandsias-headless-aarch64-unknown-linux-musl` into a non-committed build
   output directory;
3. verify `file` static/arch evidence and `VERSION` stamp evidence;
4. record the staging path contract for macOS/Windows consumers.
