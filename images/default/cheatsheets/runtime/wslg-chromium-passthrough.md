---
tags: [wslg, wsl, chromium, gui, passthrough, wayland, windows, browser]
languages: [bash, powershell]
since: 2026-05-23
last_verified: 2026-05-23
sources:
  - openspec/specs/windows-native-tray/spec.md
  - openspec/specs/vm-idiomatic-layer/spec.md
  - https://learn.microsoft.com/en-us/windows/wsl/tutorials/gui-apps
  - https://learn.microsoft.com/en-us/windows/wsl/wsl-config
  - https://github.com/microsoft/wslg
  - https://chromium.googlesource.com/chromium/src/+/HEAD/docs/ozone_overview.md
  - https://chromium.googlesource.com/chromium/src/+/HEAD/docs/linux/sandboxing.md
authority: medium
status: proposed
tier: bundled
---

# WSLg Chromium passthrough (Windows)

@trace spec:windows-native-tray
@cheatsheet runtime/wsl2-provisioning.md, runtime/wsl-browser-isolation.md

**Use when**: surfacing the in-VM Chromium container as a window on the Windows desktop, debugging blank/black Chromium windows under WSLg, or evaluating the GPU acceleration path on a specific Windows machine.

## Provenance

- Microsoft Learn `tutorials/gui-apps` — official WSLg user guide
- Microsoft Learn `wsl-config` — `[wsl2] guiApplications` toggle
- `github.com/microsoft/wslg` — WSLg architecture, source
- Chromium `ozone_overview.md` — `--ozone-platform` selection
- Chromium `sandboxing.md` — sandbox interactions under nested namespaces
- `openspec/specs/windows-native-tray/spec.md` — Tillandsias contract

## What WSLg is and is not

WSLg is the Windows Subsystem for Linux GUI integration layer. It runs a Wayland compositor (`Weston`-based) inside a small system distro (`WSLg`), composites Linux GUI windows, and forwards their pixels to the Windows desktop via RDP. Each WSL2 distro that opts in gets:

- `/tmp/.X11-unix/` — bind-mounted from the WSLg system distro (XWayland support)
- `/mnt/wslg/` — Wayland and PulseAudio sockets, runtime files
- `/dev/dxg` — para-virtualized GPU device (vGPU through Hyper-V)
- `DISPLAY=:0` and `WAYLAND_DISPLAY=wayland-0` — environment defaults

**Not** a generic X server you can configure. There is no `.Xauthority`, no DPI override knobs, no input-method config; what you get is what WSLg ships.

## When the GUI window pops up vs. when it doesn't

WSLg activates only when **all** of these are true:

1. WSL2 distro (WSL1 has no kernel namespace → no WSLg).
2. `[wsl2] guiApplications = true` in `%UserProfile%\.wslconfig` (default `true`; Tillandsias may set `false` in hardened profile — flip it back to `true` for the browser path).
3. The host has WDDM 3.0+ display driver.
4. The Linux process actually tries to open a display (`xeyes`, `chromium`, etc.).

A common Tillandsias gotcha: our `wsl2-isolation-boundary.md` profile sets `guiApplications = false` for headless reasons. The browser path **requires** flipping that to `true`. The host shell sets it per-launch by editing `.wslconfig` and issuing `wsl --shutdown` once, then bringing the VM back up.

## Chromium-in-container considerations

The Chromium container runs inside the Fedora 44 VM and renders to the WSLg Wayland socket. Three flags matter:

```bash
chromium \
  --ozone-platform=wayland \
  --enable-features=UseOzonePlatform \
  --user-data-dir=/home/forge/.chromium-data
```

- **`--ozone-platform=wayland`** picks the Wayland backend explicitly. Without it, Chromium may try XWayland (works, but adds an XWayland process between Chromium and WSLg's Weston, plus higher latency).
- **`--enable-features=UseOzonePlatform`** is the master switch on older Chromium builds; M120+ has it on by default but specifying it is safe.
- **`--user-data-dir`** outside `~/.config/chromium` avoids permissions issues in containers where the home directory is tmpfs.

### Sandbox under WSLg

Chromium's namespace sandbox **does** work under WSLg, because the WSL2 kernel has `kernel.unprivileged_userns_clone=1` and the necessary syscalls. BUT inside a podman container, the sandbox needs:

- `--cap-add=SYS_ADMIN` (or `--security-opt=no-new-privileges=false` plus suid `chrome-sandbox`)
- Access to `/proc` for the sandbox helper

The Tillandsias choice: run Chromium with `--no-sandbox` **inside the container** because the container itself provides the security boundary (cap-drop=ALL, seccomp default, --userns=keep-id). This is the same trade-off Microsoft documents for their own `wslg` smoke tests. **DO NOT** use `--no-sandbox` on a host-installed Chromium; the boundary only holds when the container is the boundary.

```bash
chromium \
  --no-sandbox \
  --ozone-platform=wayland \
  --user-data-dir=/home/forge/.chromium-data
```

The `chromium-framework` image (built via `scripts/build-image.sh chromium-framework` — already in the codebase) bakes these defaults.

### Font fallback

WSLg does not ship Linux fonts. The chromium-framework image bakes `DejaVu Sans` (and `Noto Color Emoji` for emoji rendering); without these, Chromium renders boxes for non-ASCII characters. The `Containerfile`:

```dockerfile
RUN microdnf install -y dejavu-sans-fonts dejavu-serif-fonts \
                        dejavu-sans-mono-fonts google-noto-emoji-color-fonts \
    && fc-cache -f
```

CJK text still falls back to boxes unless additional packages are installed (`google-noto-cjk-fonts`); for Phase 4 we punt on CJK and document the limitation.

## GPU acceleration

WSLg exposes `/dev/dxg` for vGPU. For Chromium to use it:

1. The container must mount `/dev/dxg` (`--device=/dev/dxg`).
2. The mesa userspace driver must be present (`mesa-dri-drivers` on Fedora).
3. The Windows host must have a vendor driver with WDDM 3.0+.

Then:

```bash
chromium \
  --use-gl=egl \
  --use-angle=d3d11 \
  --enable-features=Vulkan
```

Run `chrome://gpu` inside the launched Chromium to verify: "Graphics Feature Status" should show "Hardware accelerated" for Canvas, Compositing, and WebGL.

### Falling back to software rendering

If the host has only the Microsoft Basic Display driver (e.g. a stripped Server SKU), `/dev/dxg` is absent or non-functional. Chromium falls back to SwiftShader CPU rasterization automatically — slow, but no crash. The chromium-framework Containerfile does not require `/dev/dxg`; the host shell skips the `--device=/dev/dxg` mount when `wsl --distribution tillandsias -- test -c /dev/dxg` fails.

| Host GPU | `/dev/dxg` | Chromium path |
|---|---|---|
| NVIDIA (recent driver) | present | hardware, EGL+ANGLE-D3D11 |
| AMD Radeon (recent driver) | present | hardware, EGL+ANGLE-D3D11 |
| Intel Arc / Xe | present | hardware, EGL+ANGLE-D3D11 |
| Intel UHD (older) | present, sometimes flaky | hardware with occasional black-frame glitches; documented in WSLg #6655 |
| Microsoft Basic Display | absent | SwiftShader (software) |

## Known issues

### Clipboard sync

WSLg has a clipboard daemon that propagates host↔guest. Quirks:

- Image clipboard works for PNG only; SVG or JPEG → text fallback.
- Large clipboards (>4 MB) silently truncate.
- Selection clipboard (X11 middle-click) does NOT sync to Windows.

Workaround inside Chromium: nothing user-facing; the issues are upstream.

### IME (input methods)

WSLg does not forward Windows IMEs. Japanese/Chinese/Korean input typed in the Chromium window goes through the Linux side's IME, which is **not installed** in our minimal Fedora rootfs. Phase 4 ships without IME support; v2 considers bundling `ibus` + `mozc` if user demand justifies it.

### Hi-DPI scaling

WSLg honors `GDK_SCALE` and Chromium's `--force-device-scale-factor`. On a 4K display:

```bash
chromium --force-device-scale-factor=1.5 ...
```

Without this, text is small. The chromium-framework image reads `WSLG_DPI_SCALE` from env and applies it; the host shell sets this from the Windows display scaling (`Get-DpiScale` PowerShell snippet).

### Window decorations

Chromium uses its own decorations under Wayland by default. They look slightly different from native Windows windows; that's expected and not a bug.

## Smoke tests

### Minimal: open Chromium and dump a page

```powershell
wsl --distribution tillandsias -- chromium --headless --dump-dom https://example.com
```

If this prints HTML, Chromium and the in-VM stack work. (Headless does NOT use WSLg, so this validates only Chromium itself.)

### WSLg visible window

```powershell
wsl --distribution tillandsias -- chromium --ozone-platform=wayland https://example.com
```

A Chromium window appears on the Windows desktop. If nothing happens:

```powershell
wsl --distribution tillandsias -- /bin/sh -c "echo \$DISPLAY \$WAYLAND_DISPLAY"
# Expect: :0 wayland-0
```

If those env vars are empty, WSLg is off. Check `.wslconfig`:

```powershell
type "$env:UserProfile\.wslconfig"
# Look for [wsl2] guiApplications = true
```

### GPU check inside the launched browser

Navigate to `chrome://gpu`. The "Graphics Feature Status" panel tells you whether each pipeline is hardware-accelerated or software.

## How Tillandsias wires this

```
tray (Win32 NotifyIcon)
  └─ user clicks "Open Browser for <project>"
      └─ host-shell::launch_browser(project)
          └─ ensures .wslconfig has guiApplications=true
             (idempotent; only restarts VM if it had to flip the bit)
          └─ VmRuntime::exec(ExecSpec {
               program: "podman",
               args: ["run", "--rm", "-it",
                      "--device=/dev/dxg",        // if present
                      "-v /mnt/wslg:/mnt/wslg:ro",
                      "-v /tmp/.X11-unix:/tmp/.X11-unix:rw",
                      "-e DISPLAY=:0",
                      "-e WAYLAND_DISPLAY=wayland-0",
                      "-e XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir",
                      "tillandsias-chromium-framework:v<ver>",
                      "chromium", "--no-sandbox", "--ozone-platform=wayland",
                      "--user-data-dir=/home/forge/.chromium-data",
                      "https://app.opencode.local/<project>"],
               tty: false,
               envs: vec![],
             })
```

The browser window appears on the Windows desktop; closing the window terminates the podman container; the host shell removes the container after exit.

## Common pitfalls

- **WSLg not enabled.** `[wsl2] guiApplications=false` in `.wslconfig`. Fix and `wsl --shutdown`.
- **Black/blank window.** Usually a GPU driver quirk on Intel UHD; switch to `--use-gl=swiftshader` to confirm; if SwiftShader works, file against Microsoft/WSL with `/dev/dxg` diagnostics.
- **`Failed to connect to wayland-0` inside the container.** `/mnt/wslg` not mounted, or `WAYLAND_DISPLAY` env not forwarded.
- **Chromium crashes immediately with sandbox error.** You forgot `--no-sandbox`, or didn't `--cap-add` correctly. The container-as-boundary choice requires `--no-sandbox`.
- **Fonts as boxes.** Image missing `dejavu-sans-fonts`. Rebuild chromium-framework.
- **`xeyes` works but Chromium doesn't.** Likely `--ozone-platform` mismatch; try `--ozone-platform=x11` to confirm vs. Wayland.
- **CDP attach from the Windows host fails.** Mirrored networking is required; under NAT, `localhost:9222` inside the container is not reachable from the host. Tillandsias's `.wslconfig` profile uses mirrored mode (`networkingMode=mirrored`).

## Comparison with `wsl-browser-isolation.md`

The pre-existing `wsl-browser-isolation.md` describes the **multi-distro** model where each browser ran in its own dedicated WSL distro alongside the forge distro. This cheatsheet supersedes that approach for the new single-VM design:

| Aspect | wsl-browser-isolation.md (old) | This cheatsheet (new) |
|---|---|---|
| Browser location | Separate WSL distro `tillandsias-browser-chrome` | Container inside the one `tillandsias` VM |
| Isolation boundary | WSL distro boundary | Container boundary (--cap-drop=ALL, --userns) |
| Egress fence | nftables in the browser distro | Enclave network + proxy container (existing infra) |
| Sandbox | Chromium's own + SELinux + systemd hardening | `--no-sandbox` flag; container is the boundary |

The new model is simpler (one VM, many containers). The old multi-distro approach lives on as a reference for the security rationale; the bridges table in `wsl2-isolation-boundary.md` still applies (the new model also closes those bridges in the single VM).

## See also

- `runtime/wsl2-provisioning.md` — the VM this Chromium container runs inside
- `runtime/wsl2-isolation-boundary.md` — the bridges we close in the VM
- `runtime/wsl-browser-isolation.md` — prior multi-distro approach (superseded for the new design)
- `runtime/idiomatic-vm-exec.md` — how the host shell invokes podman inside the VM
- `runtime/macos-vz-gui-research-v2.md` — sibling problem on macOS (deferred to v2)
- `openspec/specs/windows-native-tray/spec.md` — normative contract
