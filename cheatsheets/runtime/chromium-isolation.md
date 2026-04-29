---
title: Chromium Process Isolation & Sandboxing
since: "2026-04-28"
last_verified: "2026-04-28"
tags: [chromium, security, sandbox, IPC, process-model]
tier: bundled
bundled_into_image: true
summary_generated_by: hand-curated
---

# Chromium Process Isolation & Sandboxing

**Use when**: Building containers that run Chromium, implementing security boundaries, understanding how Chromium isolates untrusted web content from the browser process and host system.

## Provenance

- https://www.chromium.org/developers/design-documents/multi-process-architecture/ — Chromium official multi-process architecture (source of truth)
- https://chromium.googlesource.com/chromium/src/+/refs/heads/main/docs/design/sandbox.md — Sandbox design across all platforms
- https://chromium.googlesource.com/chromium/src/+/0e94f26e8/docs/linux_sandboxing.md — Linux-specific sandboxing (seccomp-bpf)
- https://chromium.googlesource.com/chromium/src/+/main/docs/process_model_and_site_isolation.md — Site isolation (per-origin renderer isolation)
- https://www.chromium.org/developers/design-documents/inter-process-communication/ — IPC and Mojo framework
- https://chromium.googlesource.com/chromium/src/+/HEAD/mojo/README.md — Mojo IPC implementation details
- **Last updated:** 2026-04-28

## Quick reference

### Multi-Process Architecture

Chromium splits functionality across **multiple processes with different privilege levels**:

| Process | Privilege | Role | Isolation |
|---------|-----------|------|-----------|
| **Browser** | High | Orchestrates UI, manages tabs, I/O | Trusted code only |
| **Renderer** | Very Low | Executes untrusted JavaScript | Sandboxed via seccomp-bpf |
| **GPU** | Medium-Low | Hardware acceleration | seccomp (less strict than renderer) |
| **Audio/Network** | Low | Service-specific | seccomp + resource limits |
| **Utility** | Low | Short-lived helpers | seccomp (custom per task) |

**Why**: If a renderer process is compromised, attacker cannot escape to browser or host (defense-in-depth).

### Seccomp-BPF Sandboxing (Linux)

Chromium uses **seccomp-bpf (mode 2)** to enforce syscall policies per process type:

```
Renderer process:
  ✓ Allowed: mmap, mprotect, clone, futex, epoll, read, write, ...
  ✗ Blocked:  ptrace, bpf, module_load, keyctl, socket(AF_NETLINK), ...
```

**Key constraints**:
- `mprotect` allowed only with specific flag combinations (prevents arbitrary code execution)
- `mmap` blocked for non-contiguous VA mappings
- `socket` allowed for TCP/UDP, blocked for netlink/raw sockets
- `clone` allowed for thread creation, blocked for namespace/cgroup creation

Available since **Linux 3.5 (2012)**, integrated in **Chromium 23+ (2012)**.

### Site Isolation (Renderer Splitting)

Modern Chromium runs **one renderer process per site** to prevent same-origin vulnerabilities:

```
URL: https://a.com/page1 → Renderer A
URL: https://a.com/page2 → Renderer A (same site)
URL: https://b.com/page  → Renderer B (different site, different process)
```

**Effect on containers**: Each renderer is separately sandboxed; compromising one site doesn't expose another.

### Mojo IPC (Inter-Process Communication)

Replaced legacy Chrome IPC with **Mojo**:
- Strongly-typed message definitions (mojom files)
- Remote/Receiver pattern for type-safe communication
- Message pipes, data pipes, and shared buffers
- **3x faster, ⅓ less context switching** than old IPC

**Implication for containers**: IPC is transparent to container—no special networking or socket setup needed.

### PPAPI Plugins (Deprecated)

Old PPAPI (Pepper) plugins still use **legacy Chrome IPC** (not Mojo):
- Long-term deprecation target (phased out by 2025)
- Avoid in new codebases
- Use modern Web APIs (WebGL, WebRTC) instead

## Container-specific implications

When running Chromium in a container:

1. **Seccomp profile MUST allow these syscalls** (rendering):
   - `mmap`, `mprotect`, `madvise` (memory mapping)
   - `clone`, `futex`, `epoll_*` (threading/async)
   - `open`, `openat`, `read`, `write`, `fstat` (file I/O)
   - Full list in `cheatsheets/runtime/chromium-seccomp.md`

2. **Disable ptrace absolutely** (seccomp deny rule):
   ```
   # This blocks debugger attachment, critical for sandbox integrity
   seccomp: EACCES on ptrace() call
   ```

3. **Use `--headless=new` flag**:
   - No X11/Wayland server needed
   - Renderer runs with same sandboxing as GUI mode
   - Rendering goes to in-memory framebuffer

4. **Avoid `--no-sandbox`** in production:
   - Only use for development/testing
   - Disables ALL sandboxing; makes renderers fully trusted
   - In containers with restrictive capabilities/seccomp, may be necessary but reduces security

## References

- [Sandbox Architecture Deep-Dive](#) — Chromium official sandbox docs
- [Renderer Crashes Due to Seccomp](#) — Common troubleshooting (GPU.Renderer crashes on BPF filter match)
- `cheatsheets/runtime/chromium-seccomp.md` — Specific syscalls and BPF rules
- `cheatsheets/runtime/chromium-headless.md` — Headless rendering without display
