---
title: Chromium Seccomp Profile & Syscall Sandboxing
since: "2026-04-28"
last_verified: "2026-04-28"
tags: [chromium, seccomp, sandbox, syscall, linux, security]
tier: bundled
bundled_into_image: true
summary_generated_by: hand-curated
---

# Chromium Seccomp Profile & Syscall Sandboxing

**Use when**: Running Chromium in restricted containers, hardening against kernel vulnerabilities, implementing defense-in-depth via syscall filtering, troubleshooting renderer crashes under seccomp.

## Provenance

- https://kubernetes.io/docs/tutorials/security/seccomp/ — Kubernetes seccomp tutorial (official)
- https://crosvm.dev/book/appendix/seccomp.html — crosvm seccomp reference
- https://chromium.googlesource.com/chromiumos/docs/+/master/sandboxing.md — ChromiumOS sandboxing architecture
- https://chromium.googlesource.com/chromium/src.git/+/master/sandbox/linux/ — Chromium Linux sandbox source
- https://chromium.googlesource.com/chromium/src.git/+/master/sandbox/linux/seccomp-bpf-helpers/syscall_parameters_restrictions.h — BPF restrictions (parameter validation)
- https://en.wikipedia.org/wiki/Seccomp — Seccomp overview and history
- **Last updated:** 2026-04-28

## Quick reference

### Seccomp-BPF: Mandatory Syscalls for Chromium

These syscalls MUST be allowed for Chromium rendering to work:

#### Memory Management
- `mmap` (map memory)
- `mprotect` (change page protections; **restrict PROT_EXEC**)
- `madvise` (advise memory access pattern)
- `munmap` (unmap memory)
- `brk` (heap allocation)
- `mremap` (remap memory region)

#### Threading & Async
- `clone` (create thread; **restrict to CLONE_THREAD**)
- `futex` / `futex2` (fast userspace mutex)
- `epoll_create` / `epoll_ctl` / `epoll_wait` (event loop)
- `poll` / `select` / `pselect6` (multiplexed I/O)
- `rt_sigaction` / `rt_sigprocmask` (signal handling)
- `sigaltstack` (alternate signal stack)

#### Process & Resource Management
- `exit` / `exit_group` (terminate thread/process)
- `wait4` / `waitpid` (reap child process)
- `getpid` / `gettid` / `getuid` / `getgid` (process identity)
- `prctl` (process control; **restrict to safe operations**)
- `getrlimit` / `setrlimit` (resource limits)

#### File I/O
- `open` / `openat` / `openat2` (open file)
- `read` / `readv` (read bytes)
- `write` / `writev` (write bytes)
- `close` (close file descriptor)
- `fstat` / `lstat` (file metadata)
- `fcntl` (file descriptor control)
- `lseek` (change file position)
- `stat` / `statx` (file status)

#### Networking (if network access allowed)
- `socket` (create socket; **restrict to AF_INET, AF_INET6, AF_UNIX**)
- `connect` / `bind` / `listen` / `accept`
- `sendto` / `recvfrom` / `sendmsg` / `recvmsg`
- `shutdown` / `setsockopt` / `getsockopt`

#### Miscellaneous
- `ioctl` (I/O control; **restrict to whitelisted commands**)
- `clock_gettime` / `gettimeofday` (time queries)
- `nanosleep` (sleep)
- `getcwd` (current working directory)
- `arch_prctl` (set architecture-specific state; x86 only)

### Seccomp-BPF: Dangerous Syscalls (Block in Renderer)

These syscalls MUST be blocked to prevent sandbox escape:

| Syscall | Risk | Why Block |
|---------|------|-----------|
| `ptrace` | Debugger attachment | Can inspect/modify renderer process memory |
| `process_vm_readv` / `process_vm_writev` | Cross-process memory access | Bypass isolation |
| `bpf` | Load BPF programs | Bypass sandbox itself |
| `module_load` / `module_unload` | Kernel modules | Privilege escalation |
| `keyctl` | Kernel keyring access | Steal encryption keys |
| `socket(AF_NETLINK)` | Netlink sockets | Kernel subsystem access |
| `mount` / `umount2` / `pivot_root` | Filesystem operations | Escape container |
| `clone(CLONE_NEWNS)` / `unshare` | Namespace creation | Escape container |
| `seccomp(SECCOMP_SET_MODE_STRICT)` | Override sandbox | Disable seccomp |
| `capset` | Set capabilities | Gain new privileges |

### Seccomp JSON Profile Format

Podman/Kubernetes use JSON format for seccomp profiles:

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "defaultErrnoRet": 1,
  "archMap": [
    {
      "architecture": "SCMP_ARCH_X86_64",
      "subArchitectures": ["SCMP_ARCH_X86", "SCMP_ARCH_X32"]
    }
  ],
  "syscalls": [
    {
      "names": ["mmap", "mprotect", "munmap"],
      "action": "SCMP_ACT_ALLOW"
    },
    {
      "names": ["mprotect"],
      "action": "SCMP_ACT_ALLOW",
      "args": [
        {
          "index": 2,
          "value": 0,
          "op": "SCMP_CMP_MASKED_EQ",
          "valueTwo": 4
        }
      ]
    },
    {
      "names": ["ptrace", "bpf", "keyctl"],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 1
    }
  ]
}
```

**Key fields**:
- `defaultAction`: `SCMP_ACT_ERRNO` (deny, return error) or `SCMP_ACT_KILL_PROCESS` (kill)
- `syscalls[].args`: Constraints on syscall arguments (e.g., `mprotect` arg 2 must have bit 3 clear = no PROT_EXEC)

### Process-Type-Specific Policies

Chromium runs multiple process types; each needs different seccomp strictness:

| Process | Strictness | Extra Syscalls Allowed |
|---------|-----------|------------------------|
| **Renderer** | Strictest | None (or just memory/threading) |
| **GPU** | Medium | `ioctl` (GPU commands) |
| **Audio** | Medium | `ioctl` (audio device) |
| **Network** | Loose | All networking syscalls |
| **Utility** | Medium | Task-specific |

**Implementation**: Can't easily apply per-process seccomp in podman; apply stricter baseline and accept that utility processes are less sandboxed.

### Podman Runtime Integration

**Apply custom seccomp profile**:
```bash
podman run \
  --security-opt seccomp=/path/to/chromium-seccomp.json \
  chromium:latest
```

**Verify profile is applied**:
```bash
# Inside container, generate syscall trace
strace -e trace=system chromium --headless=new

# Check for EACCES (permission denied from seccomp)
# Expected for blocked syscalls like ptrace
```

### Common Seccomp Errors

| Error | Meaning | Fix |
|-------|---------|-----|
| `Bad system call` / `ENOSYS` | Seccomp killed the process | Add syscall to whitelist |
| `Operation not permitted` / `EPERM` | Seccomp denied (not critical) | Check defaultErrnoRet in profile |
| `Inappropriate ioctl for device` / `ENOTTY` | ioctl command blocked | Whitelist specific ioctl number |
| `GPU.Renderer crash (GPU-specific)` | GPU syscalls blocked | Add `ioctl` to GPU process allowlist |
| `Segmentation fault` | mprotect with wrong flags | Verify mprotect args constraints |

## Container Recipe

```dockerfile
FROM chromium:latest

# Copy seccomp profile
COPY chromium-seccomp.json /etc/seccomp.json

ENTRYPOINT [
  "chromium-browser",
  "--headless=new"
]
```

**Run with seccomp**:
```bash
podman run \
  --rm \
  --security-opt seccomp=/etc/seccomp.json \
  --cap-drop=ALL \
  --cap-add=SYS_CHROOT \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /dev/shm:size=256m \
  chromium:latest
```

## Minimal Chromium Seccomp Profile

See `openspec/specs/chromium-browser-isolation/spec.md` for the complete profile.

Key sections:
1. **Memory syscalls** (mmap, mprotect, madvise, munmap, brk)
2. **Threading** (clone, futex, epoll)
3. **Process management** (exit, getpid, prctl, sigaction)
4. **File I/O** (open, read, write, close, fstat)
5. **Deny list** (ptrace, bpf, keyctl, mount, seccomp, capset)

## Troubleshooting

| Symptom | Investigation | Fix |
|---------|---------------|----|
| Renderer crashes on startup | `strace` shows ENOSYS for some syscall | Add syscall to profile |
| GPU rendering fails | strace shows ENOTTY for ioctl | Add GPU-specific ioctl codes to whitelist |
| File access denied | strace shows EACCES on open() | Add file path, or relax profile (if acceptable) |
| Container doesn't start | dmesg shows kernel seccomp denial | Load profile, then run with `--security-opt seccomp=unconfined` to debug |

## References

- `cheatsheets/runtime/chromium-isolation.md` — Chromium sandboxing architecture
- `cheatsheets/runtime/chromium-headless.md` — Headless rendering
- Kubernetes seccomp tutorial — Full seccomp reference
- crosvm seccomp docs — Real-world example implementation
- Chromium sandbox/linux/ source — Upstream BPF rules and process types
