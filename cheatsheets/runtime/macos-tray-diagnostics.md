---
tags: [macos, tray, diagnostics, json, support, vfr]
languages: [rust, bash]
since: 2026-05-28
last_verified: 2026-05-28
sources:
  - internal
authority: internal
status: current
tier: bundled
---

# macOS tray diagnostics

@trace spec:macos-native-tray

**Version baseline**: `tillandsias-tray` v0.1.0+ inside `Tillandsias.app` on the osx-next platform branch.
**Use when**: an installed Tillandsias.app on a macOS host is misbehaving and you need to figure out which leg (bundle, image-root, manifest, control wire) is degraded — or you need a machine-readable health report to feed a support tool.

## Provenance

- `crates/tillandsias-macos-tray/src/diagnose.rs` — the diagnostic surface lives here (mirrors the windows-tray `notify_icon::diagnose` shape; see commits `db1619ae` `72cbf8a7` `af14f21c` `5dcd54a0`).
- `scripts/tray-diagnose.sh` — the canonical bash consumer of `--diagnose --json`.
- `scripts/install-macos.sh` — the curl-installer now runs `--diagnose --json` post-extract as a sanity check before launching the GUI.
- **Last updated:** 2026-05-28 (commits `db1619ae` `c4908438`-equiv-on-macos `5dcd54a0`).

## macOS-specific limitation vs. windows-tray

Apple's `Virtualization.framework` vsock is per-VM-handle, not per-host (macOS has no `AF_VSOCK`). A standalone `--diagnose` process therefore **cannot** reach a separately-running tray's VM control wire — it would need to be the same process that started the VM to hold the `VZVirtioSocketDevice` handle. So unlike windows-tray's `--diagnose`, the macOS report covers static/filesystem health only: bundle identity, image-root artifact presence, manifest pin, release tag. Live wire status comes from clicking the menubar icon (which the 30 s `spawn_vm_status_poller` already drives into the chip text).

## Quick reference

A single binary, two diagnostic modes. Both are non-GUI and exit with codes suitable for scripting.

| Mode                       | What it does                                                                                | Exit codes              |
|----------------------------|---------------------------------------------------------------------------------------------|-------------------------|
| `--diagnose`               | Bundled human-readable health report (version, bundle, image-root artifacts, release tag, manifest pin, wire-status disclaimer). | `0` provisioned / `2` degraded / `1` hard fail |
| `--diagnose --json`        | Same report as a structured JSON object on stdout.                                          | (same as `--diagnose`)  |

GUI mode (no flags) launches the AppKit tray itself.

`--provision-once` and `--status-once` from windows-tray have no macOS equivalent — provisioning happens lazily on tray launch, and status polling requires the running tray's `VZVirtioSocketDevice` handle (see limitation above).

## Common patterns

### Run from a Terminal, eyeball the output

```bash
/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray --diagnose
```

### Tooling consumer (the canonical pattern)

```bash
scripts/tray-diagnose.sh
# auto-discovers the exe in /Applications/Tillandsias.app/.../MacOS,
# on PATH, and in target/{release,debug}/. Set TILLANDSIAS_TRAY_EXE
# to override.
```

The script invokes `--diagnose --json`, parses with `jq`, prints colorized PASS/FAIL per check, and exits 0 / 2 / 1 mirroring the tray.

### Parse the JSON yourself

```bash
/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray --diagnose --json | \
  jq -r 'select(.provisioned == false) | "Need to materialize: \(.image_root)"'
```

### Bake into the installer

`scripts/install-macos.sh` already does this as of slice 16 (`5dcd54a0`): post-extract + codesign, it runs `--diagnose --json` and aborts with a clear "install bits broken" message on exit 1. Exit 0 or 2 proceed to `open -a` and (if jq is present) emit a `installed: version=X.Y.Z pin=abc…` breadcrumb.

## `--diagnose --json` schema (pinned)

The JSON shape is pinned by unit tests in `diagnose::tests::diagnose_report_json_keys_locked` + `_none_pin_serialises_as_null` + `_none_bytes_serialise_as_null` + `exit_code_provisioned_zero_degraded_two`. Renaming a field breaks the build, not silently the support tooling.

```jsonc
{
  "version":                "0.1.0",       // string  — CARGO_PKG_VERSION baked at build
  "in_app":                 true,          // bool    — exe path contains "/Tillandsias.app/"
  "exe_path":               "/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray",
                                           // string | null — current_exe() display
  "image_root":             "/Users/…/Library/Application Support/tillandsias",
                                           // string  — where the materializer writes
  "rootfs_present":         true,          // bool
  "rootfs_bytes":           8589934592,    // u64  | null — file size, null if missing
  "kernel_present":         true,          // bool
  "kernel_bytes":           11534336,      // u64  | null
  "initrd_present":         true,          // bool
  "initrd_bytes":           67108864,      // u64  | null
  "release_tag":            "v0.2.260526.1", // string  — embedded RECIPE_RELEASE_TAG
  "manifest_pin_aarch64_img": "6859a7bcc4a9", // string | null — first 12 hex of aarch64.img SHA-256 pin
  "provisioned":            true           // bool    — rootfs+kernel+initrd all present
}
```

No `wire` object (see limitation above). No `log_path` either — file-based tracing isn't wired on macOS yet; the AppKit tray writes to stderr which Console.app surfaces under "Tillandsias".

## Common pitfalls

- **Per-VM-handle vsock means no remote `--status-once`**: see "macOS-specific limitation" above. The user has to use the menubar chip (driven by `spawn_vm_status_poller` every 30 s) for live phase + podman_ready. A future `--attach-existing-tray` would need a host-side Unix-socket forwarder; that's a v0.0.2 enhancement.
- **Stale installed binary**: `scripts/tray-diagnose.sh`'s search order finds `/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray` first. If that's older than your repo build, set `TILLANDSIAS_TRAY_EXE=$(pwd)/target/debug/tillandsias-tray` or re-install via `scripts/install-macos.sh`.
- **Bash exit-code-as-tri-state**: `--diagnose` exits 2 when the report ran end-to-end but at least one check failed (most common: pre-first-launch where `rootfs.img` / `vmlinuz` / `initramfs.img` haven't been fetched yet). `scripts/tray-diagnose.sh` uses `set +e` around the invocation for exactly this reason — `set -e` would treat the legitimate degraded exit as a script crash. The PowerShell consumer has no equivalent footgun because `&` doesn't trip on non-zero.
- **jq missing on stock macOS**: macOS doesn't ship `jq`. `scripts/tray-diagnose.sh` errors out with "brew install jq" if jq isn't on PATH. The installer's post-install diagnose skips the jq breadcrumb silently if jq isn't present — the JSON-parse is best-effort.
- **Gatekeeper on first launch**: `Tillandsias.app` is ad-hoc signed (not notarized). The installer's right-click-Open hint addresses this; `--diagnose` from the terminal works around it entirely because Gatekeeper only gates GUI launches, not direct binary invocations from shell.
- **JSON schema change is a tooling break**: bumping a key in `DiagnoseReport` fails `diagnose_report_json_keys_locked`. If you genuinely intend the change, update the schema-pin tests AND `scripts/tray-diagnose.sh`'s jq paths in the same commit, and bump the cheatsheet "Last updated" line above.

## See also

- `runtime/windows-tray-diagnostics.md` — sibling cheatsheet for the windows-tray
- `runtime/macos-vz-gui-research-v2.md`
- `runtime/vsock-transport.md`
- `runtime/tray-state-machine.md`
