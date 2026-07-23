# macOS local-build cold-reprovision e2e smoke — PASS (2026-07-23)

- **discovered_by**: `/build-install-and-smoke-test-e2e (macos)`
- **host**: Darwin 25.5.0 arm64 (Apple Silicon), Command Line Tools only (no full Xcode)
- **branch**: `osx-next` @ `148a9076` (fast-forwarded to match `origin/linux-next`; the v0.4 integration head)
- **tested commit**: `148a9076` (`--version` embeds `git 148a9076`, freshness gate PASS)
- **evidence dir (ephemeral, gitignored)**: `target/build-install-smoke-e2e/session/`
- **verdict**: **PASS** — build + install + destroy + cold reprovision + `--diagnose` all green.
- **relates_to**: order 455 (`v04-cross-platform-smoke-queue`) — see "Scope / what this does NOT close" below.

## Result summary

| Gate | Result | Key evidence |
| ---- | ------ | ------------ |
| §1 build (`scripts/build-macos-tray.sh`) | PASS | native tray + both musl guest binaries bundled; codesign `valid on disk` + `satisfies its Designated Requirement`; `com.apple.security.virtualization` entitlement present; `built tillandsias-tray-0.3.260721.1-macos-arm64.tar.gz (26.73 MiB)` |
| §1 install (`~/Applications`) + freshness | PASS | `embedded=148a9076 head=148a9076` |
| §2 destroy VM + cache (DESTRUCTIVE) | PASS | wiped 7.5 GB `~/Library/Application Support/tillandsias` (incl. 250 GiB-sparse `rootfs.img`, `rootfs.qcow2`, `nvram.bin`) + `~/Library/Caches/tillandsias`; state dir absent after |
| §3 cold reprovision (`--provision`) | PASS | true from-network cold path: `Downloading Fedora Cloud image 0→528 MB (100%)` → `Converting` → `Image resized.` → `{"status":"provisioned"}`, exit 0 |
| §3 `--diagnose --json` | PASS | exit 0, `provisioned: true` (see JSON below) |
| §4 forge lane (`--opencode` meta-orchestration) | N/A | Linux-only lane; not applicable on macOS |

## `--diagnose --json` output (post cold reprovision)

```json
{
  "version": "0.1.0",
  "guest_version": null,
  "in_app": true,
  "exe_path": "/Users/<redacted>/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray",
  "image_root": "/Users/<redacted>/Library/Application Support/tillandsias",
  "rootfs_present": true,
  "rootfs_bytes": 268435456000,
  "kernel_present": false,
  "kernel_bytes": null,
  "initrd_present": false,
  "initrd_bytes": null,
  "release_tag": "fedora-44",
  "manifest_pin_aarch64_qcow2": "55c60a3b80d3",
  "provisioned": true
}
```

Two fields that look alarming but are **expected healthy state** (both consistent
with exit 0 / `provisioned: true`):

- `kernel_present: false`, `initrd_present: false` — the Fedora 44 Cloud image
  boots via EFI from inside `rootfs.img`; no host-side extracted kernel/initrd is
  required by the VZ boot path. `--diagnose` treats them as optional and still
  reports `provisioned`.
- `guest_version: null` — the guest-version handshake (ced9657e) is populated
  only after the VM boots and the in-guest headless reports in. `--diagnose` is a
  static disk-state probe (no boot), so `null` pre-boot is correct. This field is
  the one cold-path element not previously re-smoked on macOS; it will be
  observable once the tray boots the VM (see attended smoke below).

## Scope / what this does NOT close

Per the skill's own guardrail, a macOS PASS here means **build + install +
destroy + reprovision + `--diagnose` succeeded**. It does **NOT** exercise the
live interaction surface: vsock control wire, menu UX, PTY attach, project
enumeration, or icon rendering. Those are only reachable from a running tray a
user drives — the **attended m8 smoke** (successor tracker:
`plan/issues/macos-tray-attended-smoke-findings-2026-07-10.md`).

- The installed tray (`~/Applications/Tillandsias.app`, HEAD `148a9076`) was
  launched via `open` for the operator to run the attended interaction pass.
- **Order 455 is NOT closed by this run.** Order 455 asks for the macOS smoke
  *after v0.4 lands stable on Linux*; v0.4 has not shipped yet, so this is a
  **pre-ship cold-provision validation on the v0.4 integration head**, recorded
  as supporting evidence. The full order-455 close still needs: (a) a post-Linux-
  ship re-smoke, (b) the attended interaction pass, and (c) live proof of the
  filesystem-transport mirror lane (`TILLANDSIAS_GIT_MIRROR_PATH`) on macOS,
  which remains fixture-only.

## Follow-ups (not blockers for this smoke)

- **order 349 `macos-forge-config-trust-live-parity`** (ready, v0.5): both code
  blockers cleared; closing evidence is **operator-gated on `--github-login`** —
  a single attended run (real mirror push + TLS parity rerun). Best done during
  the attended smoke while the tray is up.
- All other open macOS packets (155 stream-refactor, 161 state-code UX, 401
  inference-tier) are `desired_release: v0.5` — out of v0.4 scope, not blockers.
- macOS in-tray EPHEMERAL RESET parity vs Windows is incomplete
  (`plan/issues/wave-review-findings-tray-chain-2026-07-22.md`) — a functional
  tray gap, but it does not affect the manual `rm -rf` + `--provision` cold path
  exercised here.
