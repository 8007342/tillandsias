---
tags: [unix-socket, ipc, interprocess-communication, socket-programming, abstract-sockets, credentials]
languages: [rust, bash]
since: 2026-04-27
last_verified: 2026-04-27
sources:
  - https://man7.org/linux/man-pages/man7/unix.7.html
  - https://man7.org/linux/man-pages/man2/socket.2.html
  - https://man7.org/linux/man-pages/man2/bind.2.html
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# UNIX socket IPC

@trace spec:container-health, spec:wsl-daemon-orchestration
@cheatsheet runtime/systemd-socket-activation.md

**Version baseline**: Linux 5.8+ (modern credential-passing semantics), macOS 10.15+, Windows WSL2
**Use when**: building high-performance inter-process communication (IPC) between a daemon and clients; passing file descriptors or credentials between processes; avoiding TCP overhead for local services.

## Provenance

- unix(7) man page — socket families, SOCK_STREAM vs. SOCK_DGRAM, abstract vs. filesystem sockets, credential passing (SO_PEERCRED, SO_PASSCRED): <https://man7.org/linux/man-pages/man7/unix.7.html>
- socket(2) man page — socket creation, address families, socket types, errors: <https://man7.org/linux/man-pages/man2/socket.2.html>
- bind(2) man page — binding to addresses, filesystem path permissions, abstract socket null-byte prefix: <https://man7.org/linux/man-pages/man2/bind.2.html>
- **Last updated:** 2026-04-27

## Quick reference

| Concept | Details |
|---|---|
| **Path-based socket** | `/run/user/1000/my-app.sock` — file on disk, permission bits like any file, survives process restart if not deleted |
| **Abstract socket** | `\0tillandsias-router` — kernel-only, no filesystem entry, no permission bits, auto-cleaned on last close |
| **SOCK_STREAM** | TCP-like sequenced, reliable (default for daemons) |
| **SOCK_DGRAM** | UDP-like datagram, message-boundary preserving, may lose packets |
| **Credential passing** | `SO_PEERCRED` (read peer's UID/GID/PID), `SO_PASSCRED` (send SCM_CREDENTIALS in ancillary data) |
| **FD passing** | Send file descriptors over a UNIX socket (socket activation use case) |
| **Listen backlog** | `listen(fd, 128)` — queue depth for pending connections |

## Common patterns

### Pattern 1 — Rust async listener (tokio)

```rust
use std::fs;
use tokio::net::{UnixListener, UnixStream};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let socket_path = "/run/user/1000/my-daemon.sock";
    
    // Clean up old socket file (if path-based)
    let _ = fs::remove_file(socket_path);
    
    let listener = UnixListener::bind(socket_path)?;
    println!("Listening on {}", socket_path);
    
    loop {
        let (socket, _addr) = listener.accept().await?;
        tokio::spawn(handle_connection(socket));
    }
}

async fn handle_connection(mut socket: UnixStream) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut buf = [0u8; 1024];
    
    loop {
        match socket.read(&mut buf).await {
            Ok(0) => break,  // EOF
            Ok(n) => {
                let _ = socket.write_all(&buf[..n]).await;
            }
            Err(e) => {
                eprintln!("read error: {}", e);
                break;
            }
        }
    }
}
```

tokio's UnixListener is non-blocking and event-driven — never polls.

### Pattern 2 — Path-based socket with explicit permissions

```rust
use std::os::unix::fs::PermissionsExt;
use std::fs;
use std::path::Path;

fn setup_socket_dir(path: &Path) -> std::io::Result<()> {
    let dir = path.parent().unwrap();
    
    // Create directory if it doesn't exist
    fs::create_dir_all(dir)?;
    
    // Set restrictive permissions (user RW only)
    let perms = fs::Permissions::from_mode(0o700);
    fs::set_permissions(dir, perms)?;
    
    Ok(())
}
```

For systemd socket activation, let `RuntimeDirectory=my-daemon` create and manage the directory instead.

### Pattern 3 — Abstract socket (ephemeral, no filesystem)

```rust
use std::os::unix::net::SocketAddr;

// Abstract sockets start with a null byte (\0), not accessible on disk
let socket = UnixListener::bind("\0tillandsias-router")?;
```

Use when:
- Socket doesn't need to survive across process restarts (process alone owns it)
- No permission-bits control needed (kernel manages isolation)
- Avoiding `/run` directory cleanup issues

### Pattern 4 — Credential passing (peer identity)

```rust
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::io::AsRawFd;
use nix::sys::socket::{setsockopt, sockopt::PassCred};

fn setup_listener_for_credentials(listener: &UnixListener) -> nix::Result<()> {
    // Enable receiving SCM_CREDENTIALS ancillary messages
    setsockopt(
        listener.as_raw_fd(),
        nix::sys::socket::SockLevel::Sol(nix::sys::socket::SockLevel::Sol),
        PassCred,
        &true,
    )?;
    Ok(())
}

// On the receiver side:
// Read ancillary data to extract SCM_CREDENTIALS (UID, GID, PID of peer)
// Most useful: check if peer is root (UID 0) before allowing privileged operations
```

Allows the server to verify the client's identity (UID, GID, PID) without additional authentication.

### Pattern 5 — File descriptor passing (socket activation)

```rust
use std::os::unix::io::{FromRawFd, AsRawFd};

fn accept_inherited_sockets() -> Vec<std::net::TcpListener> {
    // systemd passes inherited sockets as LISTEN_FD + LISTEN_PID
    let listen_pid: u32 = std::env::var("LISTEN_PID")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    
    let listen_fds: u32 = std::env::var("LISTEN_FDS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    
    if listen_pid != std::process::id() {
        return vec![];  // Not for us
    }
    
    // Sockets are FDs 3, 4, 5, ... (start at 3, 0/1/2 are stdin/stdout/stderr)
    (0..listen_fds)
        .map(|i| {
            let fd = 3 + i as i32;
            unsafe { std::net::TcpListener::from_raw_fd(fd) }
        })
        .collect()
}
```

systemd socket activation passes the socket to the daemon as an already-listening FD. The daemon claims it, calls `sd_notify("READY=1")`, and starts accepting connections.

## Common pitfalls

- **Forgetting to unlink old socket** — path-based sockets must be deleted before rebinding to the same path, or `bind()` fails with EADDRINUSE. `fs::remove_file()` before `UnixListener::bind()`.
- **Abstract socket visibility** — abstract sockets are global (all users can see them), but are auto-cleaned when the last reference closes. For privilege isolation, use path-based sockets with restrictive permissions instead.
- **Directory permissions block access** — even if the socket file has RW perms, if its parent directory is not executable (r-x), the client can't reach the socket. Always ensure parent dir has at least `0o700` or `0o755`.
- **SO_PEERCRED only on SOCK_STREAM** — datagram (SOCK_DGRAM) sockets don't support SO_PEERCRED. Use SOCK_STREAM for IPC when you need the peer identity.
- **Mixing abstract and path-based sockets** — don't switch between them for the same logical service in different runs; clients might connect to the old one. Pick one strategy and stick with it.
- **FD passing across different socket types** — you can pass a UDP socket FD over a UNIX stream socket, but the receiver must know the type. systemd encodes the type in LISTEN_FDNAME.
- **Socket listen backlog too small** — if `listen()` is called with a small backlog and the server can't `accept()` fast enough, connections are dropped silently. Use `backlog >= 128` unless you know better.
- **Credentials passing on non-SOCK_STREAM** — SO_PASSCRED and SO_PEERCRED only work with SOCK_STREAM. For SOCK_DGRAM, manually include sender identity in the message payload.

## Testing

```bash
# Connect to a UNIX socket from the shell
socat - UNIX-CONNECT:/run/user/1000/my-app.sock

# Listen on a socket from the shell
socat UNIX-LISTEN:/tmp/test.sock STDOUT

# Check socket permissions
ls -la /run/user/1000/my-app.sock

# Monitor socket activity
strace -e trace=accept,connect,read,write <daemon_pid>
```

## See also

- `runtime/systemd-socket-activation.md` — socket handoff from systemd, LISTEN_FD protocol
- `runtime/container-health-checks.md` — liveness probes (often implemented via socket health checks)
- `languages/rust.md` — tokio async patterns, error handling, unsafe FFI
- `build/cargo.md` — dependencies: `tokio`, `nix` crate for credential handling

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: Man pages are reference material (stable across distributions) but exceed image size targets.
> See `cheatsheets/license-allowlist.toml` for per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the pull cache by following the recipe below.

### Source

- **Upstream URL(s):**
  - `https://man7.org/linux/man-pages/man7/unix.7.html`
  - `https://man7.org/linux/man-pages/man2/socket.2.html`
  - `https://man7.org/linux/man-pages/man2/bind.2.html`
- **Archive type:** `single-html`
- **Expected size:** `~500 KB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/man7.org-unix-socket-docs/`
- **License:** man-pages project (GPL v2 compatible)
- **License URL:** https://man7.org/linux/man-pages/man1/man-pages.7.html#LICENSE

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET_DIR="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/man7.org-unix-socket-docs"
mkdir -p "$TARGET_DIR"
for URL in \
  "https://man7.org/linux/man-pages/man7/unix.7.html" \
  "https://man7.org/linux/man-pages/man2/socket.2.html" \
  "https://man7.org/linux/man-pages/man2/bind.2.html"; do
  FILENAME=$(basename "$URL")
  curl --fail --silent --show-error "$URL" -o "$TARGET_DIR/$FILENAME"
done
echo "Cached to $TARGET_DIR"
```

### Generation guidelines (after pull)

1. Read the pulled man pages to understand UNIX socket types, credential passing, and FD inheritance semantics.
2. If your project implements IPC via UNIX sockets (e.g., tillandsias-router), generate a project-contextual cheatsheet at `<project>/.tillandsias/cheatsheets/runtime/unix-socket-ipc.md` using `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter: `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`, `committed_for_project: true`.
4. Cite the pulled sources under `## Provenance` with `local: <cache target above>`.
