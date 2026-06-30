# Smoke E2E — macOS local-build (build/install/destroy/re-provision) — 2026-06-21

**Result:** PASS (build → install → destructive reset → cold re-provision → diagnose)
**discovered_by:** /build-install-and-smoke-test-e2e (macos)
**Host:** Darwin arm64 (Apple Silicon), `osx-next`
**Commit tested:** `cd005678` (HEAD; build embedded clean git SHA `cd005678`)
**Installed version:** `tillandsias-tray 0.1.0 (git cd005678, built 2026-06-22T00:39:27Z)`
**VERSION file:** `0.3.260620.7`
**Evidence:** `target/build-install-smoke-e2e/20260622T003926Z/`

## Gates

| Gate | Result | Evidence |
|---|---|---|
| §1 build (`scripts/build-macos-tray.sh`) | PASS exit 0 | `01-build-exit.txt`, tarball sha256 `fa12f69e…` |
| §1 artifacts (tray bin, `dist/SHA256SUMS`) | PASS | present |
| §1 codesign `--verify --deep --strict` | PASS rc 0 | `01-codesign.txt` |
| §1 install to `~/Applications` (atomic) | PASS | `01-installed-version.txt` |
| §1 freshness gate (embedded SHA == HEAD) | PASS | `embedded=cd005678 head=cd005678` |
| §2 destructive reset (rm VM dir + cache) | PASS | wiped 1.8 G; `rootfs.img` (5 GB sparse) + `rootfs.qcow2` + `nvram.bin` + `cidata.iso` removed; dirs gone |
| §3 cold re-provision (`--provision`) | PASS | download 528 MB → convert → `{"status":"provisioned"}`, no errors |
| §3 rootfs.img re-materialized | PASS | 5368709120 bytes |
| §3 `--diagnose --json` | PASS rc 0 | `provisioned:true`, `rootfs_present:true`, `release_tag:fedora-44`, `manifest_pin_aarch64_qcow2:55c60a3b80d3` |
| §4 forge continuous-enhancement | N/A | linux-only `--opencode` lane |

`--diagnose` reported `kernel_present:false` / `initrd_present:false` — expected
for the EFI/cloud-image boot path (the guest kernel lives inside `rootfs.img`),
not a finding.

## Scope caveat (NOT release acceptance)

Per the skill guardrail: a macOS PASS here means **build + install + destroy +
re-provision + diagnose** succeeded. It does **NOT** exercise the live vsock
control wire, menu UX, PTY attach, project enumeration, or icon rendering — those
need a running tray a user clicks. This run is NOT "the tray works".

In fact the interaction surface is currently **known-broken**: the GitHub-login
(and all PTY-attach) terminal flow flashes-and-dies — see
[[macos-tray-github-login-blank-terminal-2026-06-21]] (root cause) and the
re-architecture packet
[[optimization-macos-vz-idiomatic-exec-layer-2026-06-21]] (implement the
idiomatic `VzRuntime::exec` + simplify terminal launch). The mandatory macOS
release-acceptance gate remains the user-attended m8 interactive smoke.

## Net

The macOS local build/install/provision substrate path is healthy on `osx-next @
cd005678`: a destroyed VM re-provisions cold from nothing and reports a stable
diagnose schema. The remaining macOS gap is the interactive attach layer, tracked
separately.
