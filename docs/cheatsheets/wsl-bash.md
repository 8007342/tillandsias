---
tags: [wsl, windows, linux, bash, podman, filesystems]
languages: [bash]
since: 2024-01-01
last_verified: 2026-04-27
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/filesystems
authority: high
status: current
---

# WSL + Bash on Windows

How the Windows Subsystem for Linux works, how it maps paths, and how it interacts with Podman and native Windows processes.

@trace spec:cross-platform, spec:podman-orchestration

## Architecture: WSL1 vs WSL2

### WSL1 (Translation Layer)

WSL1 intercepts Linux system calls and translates them to equivalent Windows NT kernel calls at runtime. There is no Linux kernel involved. This makes it lightweight but incomplete -- some syscalls have no Windows equivalent, causing compatibility gaps.

- Linux files stored directly on the Windows filesystem (NTFS).
- No VM, no extra memory overhead.
- Faster cross-OS file access (`/mnt/c/` is just a direct NTFS path).
- Cannot run Docker/Podman (no cgroups, no namespaces).
- No `systemd` support.

### WSL2 (Lightweight VM)

WSL2 runs a real Linux kernel inside a lightweight Hyper-V virtual machine. The kernel is built and maintained by Microsoft from upstream kernel.org sources.

- Linux files stored in a virtual hard disk (ext4 VHD).
- Full system call compatibility (cgroups, namespaces, eBPF, etc.).
- Can run Docker, Podman, and other container runtimes natively.
- `systemd` support available.
- Cross-OS file access is slower (traverses 9P protocol over VM boundary).

### Feature Comparison

| Feature | WSL1 | WSL2 |
|---|---|---|
| Real Linux kernel | No | Yes |
| Full syscall compatibility | No | Yes |
| systemd support | No | Yes |
| Container support (Docker/Podman) | No | Yes |
| Cross-OS file performance (`/mnt/c/`) | Fast (direct NTFS) | Slow (9P over VM) |
| Linux-native file performance (`/home/`) | Slow (NT translation) | Fast (native ext4) |
| Memory usage | Minimal | VM grows dynamically |
| Networking | Shares host IP | NAT (separate IP, changes on restart) |
| VirtualBox/VMware compat | Yes | Requires recent versions |
| USB/serial device access | Limited | Via USBIPD-WIN |

### Tillandsias Requirement

Tillandsias requires WSL2 because Podman needs a real Linux kernel with cgroup and namespace support. WSL1 cannot run containers.

## `wsl.exe` vs `bash.exe`

Windows provides two entry points for WSL:

| | `wsl.exe` | `bash.exe` (legacy) |
|---|---|---|
| Location | `C:\Windows\System32\wsl.exe` | `C:\Windows\System32\bash.exe` |
| Purpose | Modern WSL launcher and manager | Legacy compatibility shim |
| Distro selection | `wsl -d Ubuntu` | Always uses default distro |
| Shell selection | `wsl -e /bin/zsh` or default shell | Always starts bash login shell |
| PATH behavior | May not load all installed packages | Loads full profile, packages in PATH |
| Recommended | Yes (by Microsoft and VS Code) | No (deprecated, kept for compat) |
| Management commands | `wsl --list`, `wsl --shutdown`, etc. | None |

**Warning:** If both Git for Windows and WSL are installed, `Command::new("bash")` may resolve to either one depending on PATH order. `C:\Windows\System32\bash.exe` (WSL) vs `C:\Program Files\Git\bin\bash.exe` (Git Bash) are completely different programs.

### Disambiguation

```powershell
# Check which bash is which
where.exe bash
# Typical output:
# C:\Program Files\Git\bin\bash.exe
# C:\Windows\System32\bash.exe

# Explicitly invoke WSL
wsl.exe -e bash -c "echo hello from WSL"

# Explicitly invoke Git Bash
"C:\Program Files\Git\bin\bash.exe" -c "echo hello from Git Bash"
```

## Path Mapping

### Filesystem Mount Points

WSL mounts Windows drives under `/mnt/`. Microsoft recommends against working across OS boundaries for performance: "store your files in the WSL file system if you are working in a Linux command line" and "store your files in the Windows file system" if using Windows tools.

| Windows path | WSL path |
|---|---|
| `C:\Users\alice` | `/mnt/c/Users/alice` |
| `D:\Projects` | `/mnt/d/Projects` |
| `\\wsl$\Ubuntu\home\alice` | `/home/alice` (from Windows) |
| `\\wsl.localhost\Ubuntu\home\alice` | `/home/alice` (from Windows, modern) |

The mount point prefix is configurable in `/etc/wsl.conf`:

```ini
[automount]
root = /mnt/
options = "metadata,umask=22,fmask=11"
```

### WSL2 File Access from Windows

Windows can access WSL2 files via the `\\wsl$\` or `\\wsl.localhost\` UNC paths:

```powershell
# From PowerShell / Explorer
explorer.exe \\wsl.localhost\Ubuntu\home\alice\project
```

**Performance warning:** Accessing files across the OS boundary is slow in WSL2. Store project files on whichever side runs the tools:

| Scenario | Store files in | Why |
|---|---|---|
| Building in WSL | `/home/alice/project` | Native ext4 performance |
| Building with Windows tools | `C:\Users\alice\project` | Native NTFS performance |
| Mixed (Windows editor + WSL build) | WSL filesystem + VS Code Remote | Avoids cross-OS penalty |

### `wslpath` Utility

`wslpath` converts between Windows and WSL path formats. It is built into WSL distributions.

| Command | Input | Output |
|---|---|---|
| `wslpath -u 'C:\Users\alice'` | Windows path | `/mnt/c/Users/alice` |
| `wslpath -w /mnt/c/Users/alice` | Unix path | `C:\Users\alice` |
| `wslpath -m /mnt/c/Users/alice` | Unix path | `C:/Users/alice` (forward slashes) |
| `wslpath -a ./relative` | Relative path | Absolute path |

**Usage from Rust:**

```rust
// Convert a Windows path for use inside WSL
fn wsl_path(win_path: &str) -> String {
    // Quick conversion: C:\foo\bar -> /mnt/c/foo/bar
    let s = win_path.replace('\\', "/");
    if s.len() >= 2 && s.as_bytes()[1] == b':' {
        let drive = s.as_bytes()[0].to_ascii_lowercase() as char;
        format!("/mnt/{drive}{}", &s[2..])
    } else {
        s
    }
}

// Or shell out to wslpath for accuracy:
// wsl.exe wslpath -u 'C:\Users\alice\script.sh'
```

## Windows PATH Interop

### How It Works

By default, WSL appends Windows PATH entries to the Linux PATH. This lets you run Windows executables from inside WSL:

```bash
# Inside WSL
which notepad.exe    # /mnt/c/Windows/System32/notepad.exe
code .               # Launches VS Code on Windows side
explorer.exe .       # Opens Explorer at current WSL directory
```

### Controlling Interop

`/etc/wsl.conf` controls this behavior:

```ini
[interop]
enabled = true            # Allow launching Windows executables from WSL
appendWindowsPath = true  # Append Windows PATH to $PATH in WSL
```

Setting `appendWindowsPath = false` gives a clean Linux PATH (useful if Windows PATH entries cause name collisions or slow shell startup).

To apply changes: `wsl --shutdown` then relaunch.

### Common Issues

| Problem | Cause | Fix |
|---|---|---|
| `command not found` for Windows tools | `appendWindowsPath = false` | Set to `true` or add specific paths |
| Slow shell startup | Hundreds of Windows PATH entries | Set `appendWindowsPath = false`, add only needed paths |
| Wrong tool version found | Windows `python.exe` shadows WSL `python` | Reorder PATH or use full paths |
| `.exe` suffix required | WSL interop requires the extension | `notepad.exe` not `notepad` |

## Podman on WSL2

Tillandsias uses Podman for container orchestration. On Windows, Podman runs inside WSL2.

@trace spec:podman-orchestration

### Two Approaches

| | Podman Machine (default) | Direct WSL2 Podman |
|---|---|---|
| Install | `winget install RedHat.Podman` | `apt install podman` inside WSL distro |
| How it works | Creates a dedicated WSL2 distro (`podman-machine-default`) | Podman runs in your existing WSL2 distro |
| Management | `podman machine init/start/stop` | Start WSL, podman is always available |
| Memory | Separate VM, additional overhead | Shared with your WSL2 distro |
| Windows integration | `podman.exe` on Windows PATH | Must invoke via `wsl.exe podman ...` |
| Port forwarding | Automatic | Automatic (WSL2 handles it) |
| Rootless | Yes | Yes |

### Podman Machine (What Tillandsias Uses)

Podman Machine creates and manages a dedicated WSL2 distribution:

```powershell
podman machine init          # Downloads ~1GB fedora-based WSL2 distro
podman machine start         # Starts the WSL2 distro
podman machine list          # Shows status
podman machine stop          # Stops the distro (frees memory)
```

The Windows `podman.exe` binary communicates with the Podman service running inside this WSL2 distro via a Unix socket forwarded over named pipes.

**Config paths on Windows:**

| Item | Path |
|---|---|
| Machine config | `%USERPROFILE%\.config\containers\podman\machine\wsl\` |
| Machine images | `%USERPROFILE%\.local\share\containers\podman\machine\wsl\` |
| Podman events | `%USERPROFILE%\.local\share\containers\podman\podman\` |

### Direct WSL2 Podman

If you install Podman directly inside a WSL2 Ubuntu/Fedora distro, it runs without an additional VM layer:

```bash
# Inside WSL2 (Ubuntu)
sudo apt update && sudo apt install podman
podman run --rm hello-world
```

**Advantages:** Lower memory, no separate machine to manage, tighter integration with WSL2 workflow.

**Disadvantages:** No `podman.exe` on the Windows side. Must invoke via `wsl.exe -d Ubuntu -- podman ...` or work entirely within WSL.

### Tillandsias Strategy

Tillandsias uses `podman machine` because:
1. The Windows installer (`install.ps1`) can set it up automatically.
2. `podman.exe` is available on the Windows PATH, so `Command::new("podman")` works from the Rust binary.
3. No assumption about which WSL2 distro the user has installed.

The `Os::needs_podman_machine()` check in `state.rs` auto-starts the machine if it is stopped.

## Common WSL + Windows Interop Issues

| Problem | Cause | Fix |
|---|---|---|
| `wsl --install` needs reboot | WSL2 requires Hyper-V, first install enables it | Reboot, then run again |
| "Catastrophic failure" on `wsl` | Corrupt WSL installation | `wsl --update` or reinstall |
| Podman machine won't start after sleep | WSL2 VM state stale after hibernate | `podman machine stop && podman machine start` |
| Slow file access in `/mnt/c/` | 9P protocol overhead in WSL2 | Store working files in WSL filesystem |
| DNS resolution fails in WSL2 | WSL2 auto-generates `/etc/resolv.conf` incorrectly | `[network] generateResolvConf = false` in `/etc/wsl.conf` |
| Clock drift in WSL2 | VM clock drifts after sleep/hibernate | `sudo hwclock -s` or `wsl --shutdown` and relaunch |
| Git sees all files as modified | NTFS metadata differences | Use `git -c core.fileMode=false status` |
| Permission denied on `/mnt/c/` files | Default mount options too restrictive | Set `options = "metadata,umask=22,fmask=11"` in `wsl.conf` |
| WSL2 IP changes on every restart | NAT networking, not bridged | Use `localhost` forwarding (default in recent WSL) |

## `/etc/wsl.conf` Reference

```ini
[automount]
enabled = true                # Auto-mount Windows drives
root = /mnt/                  # Mount point prefix
options = "metadata,umask=22,fmask=11"

[network]
generateResolvConf = true     # Auto-generate /etc/resolv.conf
hostname = my-wsl             # Custom hostname

[interop]
enabled = true                # Run Windows executables from WSL
appendWindowsPath = true      # Append Windows PATH

[boot]
systemd = true                # Enable systemd (WSL2 only)

[user]
default = alice               # Default login user
```

Changes require `wsl --shutdown` to take effect.

## Debugging

```bash
# Check WSL version for a distro
wsl -l -v
#   NAME              STATE    VERSION
#   Ubuntu            Running  2
#   podman-machine    Running  2

# Check if inside WSL
uname -r    # Contains "microsoft" for WSL2, "Microsoft" for WSL1

# Convert paths
wslpath -u 'C:\Users\alice'     # /mnt/c/Users/alice
wslpath -w /home/alice           # \\wsl.localhost\Ubuntu\home\alice

# Check interop
echo $PATH | tr ':' '\n' | grep mnt    # Shows Windows PATH entries

# Restart WSL entirely
wsl --shutdown

# Check Podman machine status
podman machine list
podman machine inspect
```

## Provenance

- https://learn.microsoft.com/en-us/windows/wsl/filesystems — Microsoft WSL filesystem guide; `/mnt/` mount points for Windows drives (`C:\` → `/mnt/c/`), 9P protocol performance cost, `\\wsl$\` UNC access, `wslpath` utility, recommendation to store files on the native side for best performance
- **Last updated:** 2026-04-27
