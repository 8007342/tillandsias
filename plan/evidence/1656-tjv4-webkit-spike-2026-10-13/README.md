# 1656-tjv4 measure-first spike: Playwright's Linux WebKit on this host

Host: lenovinha (Fedora Silverblue 44, podman 5.8.7, Wayland session). Date: 2026-10-13.
Every run was on a PRIVATE podman store. The operator's containers, networks
and image list were unchanged before and after each run (`*/op-*`).

## 1. The Fedora-based chromium-framework image cannot run it (`fedora-base/`)

- **Playwright 1.63.0 has no Fedora build.** It warns "your OS is not officially
  supported" and downloads the **ubuntu24.04** WebKit 26.6 build (webkit-2359).
- **Its downloader failed every attempt about 5 s in**, and reported it as a
  timeout. `curl` fetched the same URL from the host and from a container.
  The archive (107 218 719 bytes) matched the CDN's content-md5 and unpacks to
  307 MB.
- **MiniBrowser does not start on Fedora 44.** It fails with
  `libicudata.so.74: cannot open shared object file`. `ldd` lists 29
  Ubuntu-versioned libraries the image lacks, among them ICU 74,
  `libjpeg.so.8`, `libavif.so.16` and flite.
- **Conclusion:** the WebKit engine needs an Ubuntu 24.04 base, as the
  research inferred. Porting Ubuntu's ABI into the Fedora image is not a
  reasonable path.

## 2. Ubuntu 24.04 works, headless AND headful under Wayland only (`ubuntu-noble/`)

The test image is Playwright's own, pinned:
`mcr.microsoft.com/playwright@sha256:eff16c30…a4a27`, which is v1.63.0-noble,
created 2026-09-04, 2.53 GB, and carries chromium, firefox and webkit-2359.

The probe runs with the window container's hardening:
- `--network none`, `--cap-drop=ALL`, `no-new-privileges`;
- `label=disable`, as every ContainerSpec does;
- `--userns=keep-id`, `--read-only`, a tmpfs `/tmp`.

| run | result |
|---|---|
| headless | ok in 1.0 s; UA `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Safari/605.1.15`: AppleWebKit yes, `Chrome/` no |
| headful, ONLY the Wayland socket file mounted into a private tmpfs runtime dir; no DISPLAY | **ok in 1.9 s**, same UA. MiniBrowser-GTK on the host's compositor. |
| headful, Wayland plus a dummy DISPLAY | ok (DISPLAY is not needed) |
| control: headful with no display at all | fails ("Failed to open display"), so the run above really used Wayland |

Measured detours:
- **Without `label=disable`,** GTK could not connect to the compositor socket
  ("Failed to open display"). The product's ContainerSpec always sets it.
- **Benign warnings:**
  - dconf cannot create `/run/user/browser/dconf`, since the runtime tmpfs is
    root-owned 0755; give the tmpfs the user's uid.
  - No DRI or Vulkan device was passed, so it uses software rendering.
  - "Unable to acquire session bus": there is no D-Bus in the container, as
    intended.

## What the image and the window need (for the build)

- **Base:** Ubuntu 24.04, pinned by digest.
  - Playwright's image is 2.53 GB because it carries three browsers. A
    dedicated image would be smaller: ubuntu:24.04 plus nodejs plus
    `playwright@1.63.0` plus `playwright install-deps webkit` plus the WebKit
    build alone.
  - Fetch the WebKit build with checksum verification, since Playwright's
    downloader failed here.
- **Automation is the Playwright protocol, not CDP** (1656-twhk).
  - The window's entrypoint would be a node launcher: `webkit.launch({headless:false})`
    plus a context with the device's viewport, deviceScaleFactor, isMobile,
    hasTouch and userAgent, then `page.goto(url)`.
  - It would expose a tray-only Unix socket, the way the CDP relay does.
- **Network:** the same per-window `--internal` network plus SNI forwarder
  (1651-5t7n).
  - Chromium's `--host-resolver-rules` has no WebKit equivalent. The window
    must get its name-to-router mapping another way, e.g. `--add-host`
    `*.<project>.localhost` names to the forwarder, or the forwarder answering
    DNS.
  - It also cannot take an SPKI pin. The enclave CA must be trusted in the
    WebKit container's own store, never the host's.
  - These are the open design items for the build.
