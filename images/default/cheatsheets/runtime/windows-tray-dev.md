---
tags: [windows, tray, win32, rust, msvc, cross-platform, dev]
languages: [rust, powershell]
since: 2026-05-25
last_verified: 2026-05-25
sources:
  - plan/steps/windows-next-thin-tray.md
  - plan/issues/branch-and-coordination-canon-2026-05-25.md
  - methodology/distributed-work.yaml
  - openspec/specs/windows-native-tray/spec.md
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: true
---

# Windows thin-tray dev (windows-next)

@trace spec:windows-native-tray, spec:vm-idiomatic-layer

**Use when**: developing the `tillandsias-windows-tray` thin tray (the
Win32 `NotifyIcon` binary `tillandsias-tray.exe`) on a Windows MSVC host.
This is the windows-next architecture: a thin native tray driving ONE Fedora
WSL2 VM (headless + podman enclave) over vsock. NOT the older src-tauri /
podman-machine line — see the superseded `windows-native-dev-build.md`.

## Toolchain (one-time)

```powershell
# Rust MSVC (user scope, no admin):
winget install --id Rustlang.Rustup
rustup default stable-x86_64-pc-windows-msvc
# VS C++ Build Tools (admin; supplies link.exe via vswhere — rustc finds it):
winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
# WSL2 (admin + reboot):
wsl --install --no-distribution
```
Cargo lives at `%USERPROFILE%\.cargo\bin`; prepend it each PowerShell session:
`$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"`.

## Build / test / lint

```powershell
cargo build -p tillandsias-windows-tray                 # -> target\debug\tillandsias-tray.exe
cargo test  -p tillandsias-windows-tray                 # tray unit + portable_smoke
cargo test  -p tillandsias-host-shell                   # shared portable logic
cargo test  -p tillandsias-vm-layer --features download # fetch (downloader) tests
cargo test  -p tillandsias-vm-layer --features recipe   # Recipefile/manifest parser tests
cargo clippy -p tillandsias-windows-tray --target x86_64-pc-windows-msvc -- -D warnings
```
`cargo build`/`test` write progress to stderr; PowerShell may render it red and
report a nonzero pipeline exit even on success — trust the `test result: ok` /
`Finished` lines, not the PowerShell exit code.

Liveness smoke (the tray is a blocking GUI message loop — never run it
foreground): `Start-Process`, `Start-Sleep 3`, confirm the process is alive,
then `Stop-Process -Force`.

## Cross-platform gotchas (each cost a debug cycle — don't re-hit)

| Symptom | Cause | Fix |
|---|---|---|
| `environment variable HOME not defined at compile time` | `env!("HOME")` is compile-time; Windows has no `HOME` then | resolve at runtime: `var_os("HOME").or USERPROFILE .or temp_dir` (tillandsias-core image_builder.rs) |
| `cargo test` won't compile: `no UnixListener in net` | `tokio::net::UnixListener` is Unix-only; tests used the `Transport::Unix` round-trip | gate those test modules `#[cfg(all(test, unix))]` (host-shell vsock_client/provisioning) |
| clippy `manual_dangling_ptr` on `MAKEINTRESOURCE` | `n as *const u16` looks like a dangling ptr | `std::ptr::without_provenance::<u16>(n)` — exact int-id-as-pointer sentinel, lint-clean |
| `&HINSTANCE: From<HMODULE>` not satisfied (LoadIconW) | `Some(instance.into())` can't infer the param type | `let hinst: HINSTANCE = GetModuleHandleW(None)?.into();` then pass `hinst` bare |
| clippy: `CredWriteW` needless `&mut` | passing `&mut cred` where `*const` suffices | pass `&cred`; drop the binding's `mut` |
| Linux workspace build suddenly pulls reqwest/ring | a Windows-only feature enabled unconditionally | target-gate it: enable `vm-layer/download` (and `recipe`) only under `[target.'cfg(windows)'.dependencies]` so the linux-next integration build stays lean |
| `assets/tillandsias.rc missing` warning / no icon | build.rs uses `embed-resource`; needs the `.rc` (+ `.ico`) | `.rc` embeds the manifest (DPI awareness) via `1 24 "tillandsias.manifest"` and the icon via `1 ICON "tillandsias.ico"`; load it with `LoadIconW(hinst, without_provenance(1))`, fall back to `IDI_APPLICATION` |
| `cargo test` HANGS forever (test never returns; orphan test-runner + `cmd.exe` procs linger) | a unit test does a blocking Win32 `ReadFile` on a ConPTY / anonymous pipe — it blocks until data or all write-ends close, which never happens with no producing process | never unit-test blocking pipe reads; assert on something deterministic (spawn `cmd /c exit 7` → `child.wait()==7`), NOT on rendered output. Validate real pipe I/O at VM E2E. Kill stuck runners: `Get-Process tillandsias_* \| Stop-Process -Force` |
| `*mut c_void cannot be sent between threads` on `std::thread::spawn` of a closure holding a Win32-handle wrapper | edition-2021 *disjoint closure captures*: `let Wrapper(h) = w;` inside the closure captures `w.0` (the bare non-`Send` `HANDLE`), bypassing `unsafe impl Send for Wrapper` | rebind the whole wrapper first — `let w = w;` as the closure's first line, THEN `let h = w.0;` — so the `Send` wrapper is captured, not its field |

## Multi-host workflow (critical)

This host follows the distributed-work canon (`methodology/distributed-work.yaml`,
`plan/issues/branch-and-coordination-canon-2026-05-25.md`):

- **Code** (`tillandsias-windows-tray`, `vm-layer::wsl`, `vm-layer::fetch`) →
  commit to `windows-next`; the linux integration loop merges it every ~2h.
- **plan/ , methodology/ , openspec/ , cheatsheets/ , claim+progress events** →
  write DIRECTLY to `linux-next` (one ledger branch; no merge conflicts).
- **Self-claim** eligible work via a lease event before coding; mark item
  headers / task checkboxes **done** (not just an event) at completion so other
  hosts don't read finished work as open.
- **Branch hygiene**: always `git checkout <branch>` and verify
  `git branch --show-current` before plan/code writes — it is easy to still be
  on the wrong branch from a prior step. A local `linux-next` also goes stale
  fast; merge `origin/linux-next` explicitly, not the local branch.
- `cheatsheets/INDEX.md` is AUTO-GENERATED (`scripts/regenerate-cheatsheet-index.sh`)
  from each file's frontmatter — never hand-edit it.
- Never push to `main`/`linux-next`/`osx-next` **code**; never force-push.
