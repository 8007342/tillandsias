---
tags: [macos, vz, gui, chromium, research, v2, virtio-gpu, spice, vnc, deferred]
languages: [bash, swift, rust]
since: 2026-05-23
last_verified: 2026-05-23
sources:
  - openspec/specs/macos-native-tray/spec.md
  - openspec/specs/vm-idiomatic-layer/spec.md
  - https://developer.apple.com/documentation/virtualization
  - https://developer.apple.com/documentation/virtualization/vzvirtualmachineview
  - https://github.com/cirruslabs/tart
  - https://www.spice-space.org/
  - https://github.com/virtio-win/kvm-guest-drivers-windows/wiki/Vioinput
  - https://chromium.googlesource.com/chromium/src/+/HEAD/docs/ozone_overview.md
authority: low
status: proposed
tier: bundled
---

# macOS Virtualization.framework GUI passthrough — research (v2)

@trace spec:macos-native-tray (v2 work item)
@cheatsheet runtime/vz-framework-provisioning.md, runtime/wslg-chromium-passthrough.md

**Use when**: Phase 7 design work begins; the macOS user-facing browser story needs a concrete recommendation; researching whether to host Spice, VNC, or virtio-gpu on Apple Silicon for a Fedora guest.

## Provenance

- Apple Developer — `Virtualization` framework: `VZVirtualMachineView`, graphics device classes
- Tart (`github.com/cirruslabs/tart`) — third-party VZ tooling; precedent for headless+screen access
- spice-space.org — Spice protocol reference (open-source remote display)
- virtio-gpu — kernel-side virtio graphics device (used by qemu and others)
- Chromium `ozone_overview.md` — display backends Chromium can target
- `openspec/specs/macos-native-tray/spec.md` (v2 work item)

## Status: RESEARCH for v2

The Phase-1 macOS scope (per the host-shell plan, decision #9) **defers in-VM Chromium GUI passthrough**. Phase 1 ships terminal-only forges on macOS — `vm-exec podman exec -it forge bash` works, and that's the entire UX surface.

This cheatsheet captures the v2 research surface. It is **not implementation guidance**; it is the option space and recommendation for the v2 spec.

## The hard constraint

Apple's `Virtualization.framework` provides `VZVirtualMachineView` (an NSView for displaying a guest's framebuffer) — but **only for macOS guests**, not Linux. `VZGraphicsDeviceConfiguration` is a macOS-guest-only feature.

For a Linux guest, the framework provides no display protocol. The host process must implement display passthrough on top of one of:

1. virtio-vsock + a remote display protocol (Spice, VNC, custom)
2. virtio-gpu (rendered into a buffer the host can read)
3. shared memory + a custom Wayland compositor on the host
4. X11 forwarding over the existing vsock

None of these are turnkey. All require either substantial Rust code on the host or pulling in a heavy third-party stack.

## What is known (precedent)

### The M5 user finding

> "we were able to pipe a chromium from a fedora container into the host macos system, on a macbook pro with an M5 chip"

This is the empirical anchor: the tech is **feasible on Apple Silicon**. It was likely accomplished via X11 forwarding (XQuartz + ssh -X) or a Spice viewer. We do not have the recipe written down; the v2 spec needs to reproduce and document it.

### Tart project

`cirruslabs/tart` runs macOS and Linux guests on Apple Silicon using `Virtualization.framework`. For Linux guests, Tart relies on **VNC** for the GUI option: the guest runs `tigervnc-server` or similar, the host runs a VNC client. Tart packages a small VNC-viewer binary for convenience. Latency is acceptable for casual use, poor for typing-heavy or animation-heavy workloads.

## Options surveyed

### Option A — Tart-style VNC over vsock

**Stack**: in-VM `x11vnc`/`tigervnc-server` → vsock relay → host-side macOS VNC viewer (Apple Screen Sharing or `tigervnc-viewer`).

| Pros | Cons |
|---|---|
| Works today on commodity software | Latency 60-200ms; animations stutter |
| No new Rust code (Apple Screen Sharing is built-in) | VNC protocol is dated; clipboard sync is poor |
| Multi-monitor support exists | Audio not piped |
| Apple Screen Sharing handles HiDPI | Encrypted only with tunnel; raw VNC is plaintext |

**Recommendation**: viable as the MVP for v2. Ship the VNC server in the chromium-framework image with `--listen=127.0.0.1` and a vsock-to-TCP relay on the host; let the user open Apple Screen Sharing pointed at `localhost:5900`.

### Option B — virtio-gpu + Spice viewer

**Stack**: VZ Linux guest with virtio-gpu (RESEARCH: does VZ expose virtio-gpu to Linux guests? — likely NO in current macOS releases; this is the gap) → Spice server inside guest → host-side Spice viewer.

| Pros | Cons |
|---|---|
| Lower latency than VNC (<50ms target) | Spice ecosystem is QEMU-centric; macOS clients are rare |
| Smarter framebuffer encoding | Requires virtio-gpu support in VZ that is not documented |
| Clipboard, USB redirect, audio | Native Spice viewer on macOS requires Homebrew + GTK4 |

**Recommendation**: monitor Apple's `Virtualization.framework` release notes for virtio-gpu support; if it lands, this becomes the preferred path. As of macOS 15.x: not available.

### Option C — X11 + XQuartz forwarding

**Stack**: install XQuartz on macOS host; in-VM `ssh -Y` or vsock-tunneled X11 to forward Chromium windows to host XQuartz.

| Pros | Cons |
|---|---|
| Battle-tested protocol (40 years) | XQuartz adds ~250MB host install; not auto-installed |
| Per-app windows (not full-desktop VNC) | X11 auth setup (xauth, cookies) is fiddly |
| Works on Intel Macs too | Slower than VNC for full-screen redraw |
| Chromium has solid X11 backend | Apple does not ship XQuartz; community-maintained |

**Recommendation**: not a Tillandsias default — requiring users to install XQuartz is friction. Document as an "advanced user" option.

### Option D — Wayland + native macOS Wayland compositor

**Stack**: in-VM Wayland client (Chromium with `--ozone-platform=wayland`) → vsock-tunneled Wayland → host-side Wayland compositor.

**Status**: no production-grade Wayland compositor exists for macOS as of 2026. Some experimental ports exist (cage-on-macos), none stable.

**Recommendation**: not feasible for v2; revisit if a viable macOS Wayland compositor emerges.

### Option E — Headless Chromium + CDP from a macOS-native browser shell

**Stack**: in-VM Chromium headless on a CDP port; macOS host has a tiny WKWebView-based shell that drives the headless via CDP and renders pages.

| Pros | Cons |
|---|---|
| No display passthrough needed | "It's not really Chromium" — different rendering engine? |
| Native macOS UX | Loses agent-driven workflows that depend on the real Chromium UI |
| Fast (everything runs locally) | Complex sync between WKWebView state and the underlying Chromium |

**Recommendation**: too divergent from the Windows model (where the user sees the actual in-VM Chromium). Cross-platform consistency suffers.

## Recommendation for the v2 spec

**Start with Option A (VNC over vsock) as MVP**, then upgrade to Option B (virtio-gpu + Spice) if/when VZ exposes virtio-gpu to Linux guests.

```
v2 MVP target:
  - In-VM image: chromium-framework + tigervnc-server (port 5900 on loopback)
  - Host-side: vsock-to-TCP relay listening on host's 127.0.0.1:5900
  - User UX: tray menu item "Open Browser" → opens Apple Screen Sharing
             pre-configured to vnc://127.0.0.1:5900
  - Latency budget: <200ms; document this in the spec
  - Security: VNC password derived from per-session token; never reused
```

## Open questions for the v2 spec

These need empirical answers before the v2 spec is normative:

1. **Does VZ on macOS 15.x expose virtio-gpu to Linux guests?** Test by building a guest config with `VZVirtioGraphicsDeviceConfiguration` (if it exists in the SDK) and observing whether the guest's kernel sees a `virtio-gpu` device. If yes, Option B becomes plausible.
2. **Latency budget acceptable for users?** Need 30+ minute pilot sessions with real developers on real M-series machines. The target is "comfortable for reading PRs / clicking through deploys"; not "AAA gaming".
3. **Multi-monitor support.** Apple Screen Sharing handles guest-side multi-monitor when the guest VNC server supports it. tigervnc does; x11vnc partially. Decide one server.
4. **Security boundary for the display stream.** VNC traffic between the in-VM server and the host VNC viewer crosses vsock; vsock has no encryption. Either tunnel through SSH (re-introduces auth complexity) or accept that vsock-on-localhost is implicit boundary. The v2 spec must pick.
5. **Multi-monitor pixel scaling on Retina.** Apple Screen Sharing pixel-doubles, which can look fuzzy. virtio-gpu would be sharper. Worth verifying user perception.
6. **Audio passthrough.** None of the options above ship audio by default. If a Chromium use case needs audio (WebRTC demos, video conferencing), add a PulseAudio-over-vsock layer or just document audio as N/A for v2.
7. **Clipboard sync.** VNC supports it crudely (text only). Spice would be better. Decide whether clipboard is in-scope for v2.
8. **What does the user click to launch?** Phase 1 macOS tray has a stub "Open Browser" menu item that says "macOS browser passthrough deferred to v2"; v2 turns it into a real launcher.

## Sibling reference

Windows tray ships **WSLg Chromium passthrough** as part of Phase 4. See `wslg-chromium-passthrough.md` for the parity contract; v2 macOS aims for the same user-visible behavior (click a menu item → in-VM Chromium window appears on the macOS desktop).

## Risks for v2

- **Apple removes virtio-vsock or restricts VZ APIs** (low probability; VZ is a stable framework).
- **VNC ecosystem on macOS regresses** (Apple Screen Sharing has been stable for 15+ years; low risk).
- **Performance is unacceptable** even on M5+; mitigation = degrade to terminal-only, surface a clear message.
- **App Store / notarization rejects the VNC relay** as suspicious; mitigation = ship as `tillandsias-tray.app` Developer ID-signed (no App Store distribution planned).

## What ships in Phase 1 (macOS)

For the avoidance of doubt, the **Phase 1 macOS deliverable** has:

- AppKit NSStatusItem tray with parity menu (projects, agents, etc.)
- VZ-provisioned Fedora 44 guest with vsock control wire
- "Attach Here" → opens Terminal.app or iTerm2 running `vm-exec podman exec -it forge bash`
- "Open Browser" → menu item disabled, with explanatory tooltip "Available on Linux and Windows; macOS support in v2"

The forge containers themselves run identical code on all three platforms (Linux, Windows-via-WSL, macOS-via-VZ). Only the GUI surface differs.

## Common pitfalls (anticipated for v2 implementation)

- **Assuming Spice "just works" on macOS.** It does not. The Spice viewer for macOS is a Homebrew-installed GTK4 app; bundling it is non-trivial.
- **Forgetting that VNC requires the in-VM X server.** A pure Wayland Chromium won't be visible to a VNC server; install XWayland or run an X11-only browser in the v2 image.
- **Latency tests on the local network ≠ tests on vsock.** Vsock is faster than gigabit LAN; benchmark on the actual transport, not a TCP emulation.
- **Trusting Apple Screen Sharing's "auto-discover" feature.** It can pick up the wrong VNC server (e.g., the user's own host VNC). Use explicit `vnc://127.0.0.1:5900` URLs.
- **Treating the user's M-series chip as a guarantee.** Some M1/M2 base models have less VRAM and lower vGPU performance than M3+. Capability checks at provision time.

## See also

- `runtime/vz-framework-provisioning.md` — Phase 1 VZ guest provisioning this builds on
- `runtime/wslg-chromium-passthrough.md` — sibling Windows path (the parity target)
- `runtime/vsock-transport.md` — the transport the v2 display protocol rides on
- `runtime/idiomatic-vm-exec.md` — terminal-mode UX that ships in Phase 1
- `openspec/specs/macos-native-tray/spec.md` — Phase 1 contract; v2 spec to be authored separately
