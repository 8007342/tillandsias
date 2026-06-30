# Unified curl-install OS-parity — `install.sh` is Linux-only — 2026-06-22

**Filed:** 2026-06-22 (operator-directed, macOS release/e2e session)
**Kind:** enhancement (cross-platform parity)
**Status:** ready
**Trace:** `spec:macos-tray-build-and-release`, `spec:macos-native-tray`,
`spec:install-ux`

## Operator vision

"Eventually we want feature parity for all versions: macos/linux/windows —
curl install to runtime should go unattended: just downloads, recipes, and
idiomatic abstraction layers." One curl-install entry that detects the OS and
installs the right artifact, which then provisions the runtime via the platform's
idiomatic layer (podman on Linux, `macos::virt`/Virtualization.framework on
macOS, WSL2 on Windows).

## Current state (gap)

- `scripts/install.sh` is **Linux-only** — it `die`s on non-Linux:
  `"unsupported OS: $OS. Tillandsias v0.2 releases are Linux-only."`
  (`scripts/install.sh:135-140`). It installs the Linux musl binary + podman flow.
- macOS has a **separate** `scripts/install-macos.sh` (curl-installs
  `Tillandsias.app` from the release, SHA-256 verify, /Applications, optional
  Login Item). Documented entry:
  `curl -fsSL .../releases/latest/download/install-macos.sh | bash`.
- Windows presumably has its own path (install-windows.ps1).

So there is **no single `install.sh` that dispatches per-OS**; each platform has
a bespoke installer. The end-user "one curl command, any OS" parity does not
exist yet.

## Proposed (smallest first)

1. `install.sh`: detect `uname -s` and **dispatch** — Linux keeps the current
   path; Darwin re-execs / forwards to the macOS installer logic; otherwise a
   clear pointer. Closure: `curl … install.sh | bash` on macOS installs the tray
   (instead of `die`ing), and on Linux is unchanged.
2. Align the post-install runtime bring-up so all three go **unattended**:
   download → recipe/materialize → idiomatic layer (podman / `macos::virt` /
   WSL2) with no manual `--init`. macOS already auto-boots the VM on tray launch;
   confirm Linux/Windows match the "just works after install" bar.
3. A cross-platform install litmus per OS asserting: curl-install →
   provisioned-runtime with zero manual steps.

## Notes

- Surfaced while running the macOS curl-install e2e of `v0.3.260622.4` (the
  end-user flow: `install-macos.sh` → `Tillandsias.app` → `macos::virt` → Fedora
  44 VM → fetch released headless). The macOS idiomatic layer (VzRuntime + exec)
  is the foundation; this packet is about the *install entry* parity, not the
  runtime layer (which now exists on macOS).
- Coordinate with the install-UX owner; `install.sh` is shared (Linux-owned),
  so a dispatch change is a cross-host edit.
