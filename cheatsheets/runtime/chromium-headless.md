---
title: Chromium Headless Rendering (No Display Server)
since: "2026-04-28"
last_verified: "2026-04-28"
tags: [chromium, headless, rendering, xvfb, /dev/shm]
tier: bundled
bundled_into_image: true
summary_generated_by: hand-curated
---

# Chromium Headless Rendering

**Use when**: Running Chromium in containers or servers without X11/Wayland, automating screenshot/PDF capture, reducing memory/CPU overhead in batch rendering.

## Provenance

- https://developer.chrome.com/docs/chromium/headless — Chrome for Developers official headless documentation
- https://chromium.googlesource.com/chromium/src/+/lkgr/headless/README.md — Chromium headless module source
- https://developer.chrome.com/blog/headless-chrome — Headless Chrome deep dive
- https://github.com/cgoldberg/xvfbwrapper — Xvfb wrapper (legacy reference, not recommended for new work)
- https://github.com/atlassian/docker-chromium-xvfb — Docker Chromium+Xvfb example (legacy)
- https://elementalselenium.com/tips/38-headless — Headless testing best practices
- **Last updated:** 2026-04-28

## Quick reference

### Headless Mode Versions

| Flag | Release | Rendering | GPU | WebGL | Use Case |
|------|---------|-----------|-----|-------|----------|
| `--headless` (old) | Chrome 59+ | Partial | Limited | No | Legacy headless |
| `--headless=new` | Chrome 112+ | Full | Yes | Yes | **Recommended** |
| Headful (GUI) | All | Full | Yes | Yes | Desktop mode |

**Chrome 112+ default**: Use `--headless=new` (identical rendering to headful, but no window display).

### What Headless Does NOT Need

Contrary to older practice, **modern headless Chromium does NOT require**:
- X11 display server (no Xvfb needed)
- Wayland compositor
- GPU X11 drivers
- Virtual framebuffer

**Rendering happens in-memory**; output captured via Chrome DevTools Protocol.

### /dev/shm Sizing

Chromium uses `/dev/shm` (POSIX shared memory) for:
- Tab process IPC
- Shared GPU memory (if GPU enabled)
- GPU texture uploads

**Container default**: `/dev/shm` is 64MB (often insufficient).

**Solution**: Explicitly mount larger tmpfs:
```bash
podman run --tmpfs /dev/shm:rw,size=256m <image>
```

**If OOM crashes occur**: Use `--disable-dev-shm-usage` flag (redirects to `/tmp`, slower but more stable):
```bash
chromium-browser --headless=new --disable-dev-shm-usage
```

### Capturing Output (CDP)

Headless Chromium does NOT write output files directly. Capture via **Chrome DevTools Protocol**:

```bash
# Screenshot (PNG)
curl http://localhost:9222/json/version | jq -r '.webSocketDebuggerUrl' | \
  xargs -I {} node -e "const c = require('chrome-remote-interface'); c().then(async client => { \
    await client.Page.enable(); \
    const data = await client.Page.captureScreenshot(); \
    require('fs').writeFileSync('screenshot.png', Buffer.from(data.data, 'base64')); \
  })"

# PDF
# Similar pattern using Page.printToPDF()
```

Or use higher-level tools:
- **Puppeteer** (Node.js): `await page.screenshot({path: 'screenshot.png'})`
- **Playwright** (Node.js, Python, .NET): `await page.screenshot(path="screenshot.png")`
- **Selenium** (multiple languages): `driver.save_screenshot("screenshot.png")`

### WebGL in Headless

| Mode | WebGL 1.0 | WebGL 2.0 | Status |
|------|-----------|-----------|--------|
| `--headless` (old) | No | No | Not supported |
| `--headless=new` | Yes (GPU) | Yes (GPU) | Full support |
| `--disable-gpu` | SwiftShader | SwiftShader | Software fallback |

**GPU requirement**: If WebGL tests needed, pass `--device /dev/dri/renderD128` to container (for Intel/AMD iGPU).

### Comparison: Xvfb vs Headless=new

| Factor | Xvfb | `--headless=new` |
|--------|------|-----------------|
| **Setup** | Install X11 server (200MB+) | None; built-in |
| **Memory** | Overhead of X server (~30MB) | None |
| **Startup time** | ~500ms (start Xvfb, start Chrome) | ~100ms (just Chrome) |
| **Rendering fidelity** | Identical | Identical |
| **WebGL support** | Via X11 GPU drivers (fragile) | Native (robust) |
| **Container size** | +200MB | +0MB |

**Verdict**: `--headless=new` is **strictly better**. Only use Xvfb for Chrome < 112.

## Container recipe

```dockerfile
FROM fedora:43
RUN dnf install -y chromium

ENTRYPOINT ["chromium-browser", "--headless=new"]
```

Run with:
```bash
podman run --rm \
  --tmpfs /dev/shm:rw,size=256m \
  --tmpfs /tmp:rw,size=512m \
  --cap-drop=ALL \
  --cap-add=SYS_CHROOT \
  --device /dev/dri/renderD128 \
  my-chromium-image http://example.com
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Cannot allocate memory` | `/dev/shm` full | Increase tmpfs size or use `--disable-dev-shm-usage` |
| `GPU.Renderer crash` | seccomp blocking GPU syscalls | Whitelist `ioctl`, `mmap` with PROT_EXEC |
| `WebGL: context lost` | GPU not available | Pass `--device /dev/dri/renderD128` or use `--disable-gpu` |
| `Sandbox error: seccomp` | Restrictive seccomp profile | Check `cheatsheets/runtime/chromium-seccomp.md` |

## References

- `cheatsheets/runtime/chromium-isolation.md` — Process isolation & sandboxing
- `cheatsheets/runtime/cdp-security.md` — Chrome DevTools Protocol security
- `cheatsheets/runtime/container-gpu.md` — GPU passthrough in containers
