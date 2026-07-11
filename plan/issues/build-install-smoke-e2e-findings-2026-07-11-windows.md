# Windows build-install-smoke e2e findings — 2026-07-11

- discovered_by: `/build-install-and-smoke-test-e2e` (windows), order 282 cycle
  (agent `windows-bullo-claude-20260711T182324Z`)
- evidence: `target/build-install-smoke-e2e/20260711T191912Z/*` +
  `%LOCALAPPDATA%\tillandsias\logs\tray.log`

# Run 4 — 2026-07-11T19:19Z series — attempt 1 FAIL (root-caused + fixed), attempt 2 pending

First Windows e2e exercising the order 282 embedded guest headless (assets no
longer zero-byte placeholders).

## Attempt 1 — FAIL at gate 3 (cold provision handshake timeout)

| Gate | Result |
|---|---|
| 1 build (`scripts/build-windows-tray.ps1`, staged x86_64 embed) | PASS — `tillandsias-tray 0.3.260711.7 (9d311c5c)`, embedded SHA == HEAD, integrity pin test ok |
| 2 destroy (`wsl --unregister` + cache/logs dirs) | PASS — distro unlisted, dirs removed |
| 3 cold re-provision (`--provision-once`) | **FAIL** — `RESULT: FAILED — control-wire handshake did not succeed within budget: attempt 36: connect+handshake timed out after 30s` |

The embed path itself engaged correctly on the pristine provision
(tray.log 19:34:17Z: `Injecting embedded tillandsias-headless binary
arch=x86_64`), the guest booted, but the headless never answered on vsock.

## Root cause (found by inspection, same cycle)

`scripts/build-guest-binaries.sh`'s **cargo fallback built with `--features
tray`, which does NOT enable the vsock listener**. The canonical Nix packages
(flake.nix `tillandsias-headless-{x86_64,aarch64}-musl`) build with
`--features listen-vsock`; without it `tillandsias-headless --listen-vsock
42420` cannot bind the control wire (main.rs gates the listener on the
feature), so the unit runs but the wire never comes up. Release-fetched
binaries are Nix-built, which is why every previous fetch-path provision
handshook fine — the bug only bites the cargo-fallback staging lane that
order 282 first exercised.

Fixed in the same cycle: cargo fallback now builds `--features listen-vsock`
(matching the flake), with a comment pinning the equivalence. PLEASE REVIEW:
linux — script is linux write-scope; fix was required to unblock the windows
half of order 190/282.

## Attempt 2 — PASS (all gates + order 282/154 extended verification)

Re-run after rebuilding both staged arches with `listen-vsock` at the
release-merge HEAD 9632165a (VERSION 0.3.260711.8 — windows-next
fast-forwarded to the release commit because the linux coordinator had
already merged this cycle's pushed windows commits before cutting
v0.3.260711.8).

| Gate | Result |
|---|---|
| 1 build + install | PASS — `tillandsias-tray 0.3.260711.8 (9632165a)`, embedded SHA == HEAD, integrity pin test ok, staged x86_64 embed |
| 2 destroy | PASS — distro unlisted, cache/logs removed |
| 3 cold re-provision (`--provision-once`) | PASS — `RESULT: VM Ready — control wire up ✓`, exit 0; `Injecting embedded tillandsias-headless binary arch=x86_64` (20:14:04Z); handshake `wire_version=2 attempt=1` |
| 3 diagnose (`--diagnose --json`) | PASS — exit 0 with live tray (exit 2 degraded before tray launch), `version 0.3.260711.8`, `build_commit 9632165a` |
| 4 forge | n/a (linux-only lane) |

### Extended verification (orders 282 + 154)

- **Order 282 exit criterion 1**: `build-guest-binaries.sh --verify` in-VM:
  `Verification SUCCESS: both binaries are correct and match VERSION
  0.3.260711.8`; unit pin `embedded_guest_headless_matches_workspace_version`
  green (and demonstrated failing loud on a real .5-vs-.7 skew earlier in the
  cycle).
- **Order 282 exit criterion 2 + order 154 slice-3 live check (previously
  structurally blocked)**: live tray on the pristine embedded-binary guest
  logged `vm status push subscription established (polls suppressed, SC-07)`
  (20:15:54Z) — the FULL-TOPIC success line; NO legacy-fallback line in
  tray.log. First-ever Windows full-topic live verification including
  SubscriptionTopic::LocalProjects.
- **Order 282 exit criterion 3**: embedded-asset path writes the no-op
  fetch-headless.sh (fetch demoted to absent-asset fallback), absent-asset
  path unchanged + warn added; pinned by existing + new unit tests.
- Guest version skew from run 3 is CLOSED on this host: guest and wrapper are
  the same source revision with no network fetch.
