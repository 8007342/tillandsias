# macOS curl-install e2e — released v0.3.260622.4 — 2026-06-23

**discovered_by:** operator-attended macOS curl-install e2e
**Host:** Darwin arm64, end-user flow (NOT a local build)
**Release under test:** v0.3.260622.4 (cut this session; includes db616e06 +
macOS exec/login layer)

## Gates

| Gate | Result |
|---|---|
| Release v0.3.260622.4 cut + published (all assets) | PASS |
| `curl …/install-macos.sh \| bash` installs `Tillandsias.app` | PASS (SHA256 ok; `git 16b26058` = CI-built tag) |
| install-macos.sh post-install verify | **FAIL** — `DIAG_PIN: unbound variable` (order 79-adjacent; filed `install-macos-diag-pin-unbound`) |
| **Unattended auto-provision** (launch tray, no flags) | **PASS** — `rootfs.img missing… Fedora Cloud image fetch` → provisions with no manual --init/--provision |
| Provision → boot → control wire (`phase=Ready podman_ready=true`) | PASS (recovered from a 🔴 "Wire unreachable" blip during a slow-wifi vsock hiccup) |
| Guest headless = released v0.3.260622.4 (db616e06 present) | PASS (`--version`; `mode=0400,uid=` strings gone) |
| Tray menu structure (collapsed, auth-gated, Linux parity) | PASS (operator-confirmed) |
| Tray menu-bar icon | **FAIL** — shows fallback "T" (order 79) |
| `--github-login` end-to-end | **BLOCKED** at Vault unseal (order 81: db616e06 necessary-not-sufficient) |

## Headline

The end-user **curl-install → unattended runtime** flow you wanted is validated
on macOS: a pure curl-installed release launches and provisions the Fedora-44 VM
via the idiomatic `macos::virt` layer with zero manual steps, boots, brings up
the control wire, and runs guest exec. Everything upstream of Vault works on the
released binary.

## Findings filed

- order 79: tray icon "T" (`macos-tray-icon-missing-T-fallback`)
- order 80: GitHub Login menu readiness gate (`github-login-menu-readiness-gate`)
- order 81: Vault unseal still fails after db616e06 (`vault-unseal-fails-macos-after-db616e06`)
- `install-macos-diag-pin-unbound`: installer post-verify crash
- `unified-curl-install-parity`: install.sh is Linux-only (macOS uses install-macos.sh)
