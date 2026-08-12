# portable-zero-dependency-runtime-audit — TOMBSTONE

Filed 2026-08-08 from the Intel N100 field host (`Esmeralda`) for packet
`portable-zero-dependency-runtime-audit` (order 620-duta). **Distilled into the
owning spec 2026-08-12 (criterion 4); this file is now a pointer.**

The content lives at:

- `openspec/specs/windows-native-tray/spec.md` → **Runtime dependency surface**
  (the inventory: what an end-user machine actually needs, what is dev-time
  only, and which of it is observable at runtime)
- `openspec/specs/windows-native-tray/spec.md` → **Invariant: The tray imports
  only DLLs Windows ships in-box** (the promise, made falsifiable)

## What the audit got wrong, and why that is the point

The original inventory asserted in prose that the tray "links only OS-shipped
Windows libraries … no VC redist". **That was false**, and had been false for as
long as there was a Windows tray: Rust's MSVC targets link the C runtime
dynamically by default, so `vcruntime140.dll` — a Visual C++ Redistributable
component — sat in the binary's import table. No machine that ever ran the
binary noticed, because every machine that ran it was a developer machine with
the redist already installed.

An inventory written as prose cannot catch that. The packet's own operator
directive said so on the day it was filed: runtime dependencies must be
*detectable at runtime*, not asserted. Criterion 3 built the detector, and the
detector found it immediately.

Fixed by `-C target-feature=+crt-static` for the `*-pc-windows-msvc` targets;
pinned by `litmus:tray-import-surface-os-only`.

## Where each exit criterion landed

1. `--diagnose --json` reports guest wiring + last reconcile outcome →
   `guest_wiring` field, cheatsheet
   `cheatsheets/runtime/windows-tray-diagnostics.md` is schema authority.
2. Headless preflight reports `vsock_loopback loaded|missing` →
   `crates/tillandsias-headless/src/main.rs`, emitted before the listener binds.
3. Litmus pins the tray's import surface →
   `scripts/check-tray-import-surface.sh` +
   `openspec/litmus-tests/litmus-tray-import-surface-os-only.yaml`.
4. Inventory distilled to the owning spec → this tombstone.

## Related

- 627-sgtt — the packet the "stale adopted guest" section of the original audit
  was written about; its deployment question is now answered by `guest_wiring`.
- 695-r7k8 — the staging skip that let stale guest binaries into the embed.
- 689-gipe — the tray build embedding a stale staged binary.
