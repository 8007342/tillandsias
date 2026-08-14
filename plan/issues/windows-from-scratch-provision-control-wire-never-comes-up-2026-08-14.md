# From-scratch Windows provisioning fails: the control wire never comes up

Filed 2026-08-14 (windows host, operator-requested full e2e before a v0.4
release). Order 735-ewzp.

## What was run

A genuine from-scratch cycle, in this order:

1. Built the guest binary from **current source** in the WSL build distro
   (`cargo build --release --target x86_64-unknown-linux-musl -p tillandsias-headless`,
   3m55s) and staged it into `target-guest/`. Verified it carries the workspace
   VERSION: `strings … | grep -c 0.4.260812.1` → `1`.

   This step matters. Without it the staged guest predates the checkout, the
   build refuses to embed it (order 689-gipe), and the fresh guest fetches the
   **published 0.4.260810.1** instead — so the run would have validated the last
   release rather than current source.

2. `scripts\build-and-install-windows-local.ps1 -Purge` — full destructive
   reset: unregistered the `tillandsias` WSL distro, removed the cache, logs,
   install dir and shortcuts.

3. `scripts\build-and-install-windows-local.ps1 -Provision -Launch` — release
   build (2m36s), install, and real provisioning.

## What happened

The build and install succeeded and the embed worked:

```
Staged guest binary into assets (x86_64 host): tillandsias-headless-x86_64-unknown-linux-musl
Built: …\target\release\tillandsias-tray.exe
  tillandsias-tray 0.4.260812.1 (a4705a10)
```

Provisioning then got most of the way and stalled at the last step
(`%LOCALAPPDATA%\tillandsias\logs\tray.log`):

```
19:03:29 provisioning phase "Setting up Fedora Linux…"
19:03:29 provisioning phase "Downloading Fedora rootfs…"
19:03:53 provisioning phase "Installing Tillandsias…"
19:05:14 guest root headroom OK: 954 GiB available
19:05:18 Injecting embedded tillandsias-headless binary arch=x86_64
19:05:23 provisioning phase "Starting Fedora Linux…"
19:05:25 WSL start poke succeeded
19:05:25 provisioning phase "Connecting…"
19:05:55 control wire not ready; backing off attempt=1 … (30s timeout each)
…
19:12:56 ERROR control wire never came up on a fresh VM start
19:12:56 WARN  WSL service appears wedged. Attempting recovery via wsl --shutdown...
19:13:00 ERROR WSL recipe provisioning failed
19:13:03 ERROR launch-failure diagnostics bundle written
```

Ten attempts, 30s each, ~7.5 minutes, then bounded recovery. `--diagnose`
reports `WSA_ERROR(10060)` — connect timed out — against a utility VM that
`hcsdiag list` confirms is **Running**.

## What is NOT the cause (each checked, not assumed)

* **The guest binary.** It runs inside the distro and reports the right
  version: `/usr/local/bin/tillandsias-headless --version` → `Tillandsias
  v0.4.260812.1`, exit 0. A cargo-musl build links static non-PIE where Nix
  produces static-pie; that difference did not stop it executing.
* **The guest service.** `systemctl status tillandsias-headless` → `active
  (running)`, `Main PID … /usr/local/bin/tillandsias-headless --listen-vsock 42420`,
  all three `ExecStartPre` preflights `SUCCESS`.
* **A missing Hyper-V vsock transport.** This was my first hypothesis and the
  evidence **refuted** it: `dmesg` shows `hv_vmbus: registering driver hv_sock`
  and `NET: Registered PF_VSOCK protocol family`, and `/sys/module/hv_sock`
  exists. The transport is present.
* **Disk.** 954 GiB free in the guest, 219 GB on C:.

## The strongest open lead

Windows routes host→guest Hyper-V socket connections through service GUIDs
registered under

```
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices
```

On this host that key contains **only** the two built-in entries:

```
999E53D4-3D5C-4C3E-8779-BED06EC056E1  VM Session Service
A5201C21-2770-4C11-A68E-F182EDB29220  VM Session Service-2
```

There is no entry for port 42420, whose Linux-vsock template GUID is
`0000a5b4-facb-11e6-bd58-64006a7986d3` — a template the code itself computes
(`crates/tillandsias-vm-layer/src/transport_windows.rs:37-38`, asserted at
`:616` and `crates/tillandsias-windows-tray/src/hvsocket.rs:202`).

**Nothing in this repository ever writes that registry key.** A repo-wide
search for `GuestCommunicationServices` returns no writer — only the GUID
template used to build the address.

CAUSATION IS NOT PROVEN. This host had a working wire on 2026-08-11
(`plan/loop_status.md`: guest 0.4.260810.1, "control wire established"), so
either the registration existed then and was removed — by the purge, or by the
WSL 2.7.11.0 update this host now runs — or the connection never needed it and
something else regressed. The decisive experiment is one elevated registry add
plus a retry, which is a machine-scope change and is therefore left to the
operator rather than done unilaterally.

## The fail-loud gap, which is real regardless of root cause

The guest preflight decides vsock readiness like this
(`/usr/local/lib/tillandsias/headless-preflight.sh`):

```bash
if [[ ! -e /dev/vsock ]]; then
  echo "[tillandsias-preflight] vsock_device=missing"; exit 1
fi
echo "[tillandsias-preflight] vsock_device=present"
```

`/dev/vsock` is provided by `vsock_loopback` alone — which this image loads
deliberately via `/etc/modules-load.d/tillandsias-vsock.conf`. So the node
exists, the preflight passes, systemd reports the service `active (running)`,
and **every readiness signal on the guest side is green while the host cannot
reach it at all**. The one thing none of them checks is whether a
*host-reachable* transport is bound.

That is this project's recurring shape — a check that consults a proxy for the
property instead of the property — and it is why the failure presents as seven
and a half minutes of silence followed by a generic timeout rather than as a
named fault.

## Consequence for the pending v0.4 release

A from-scratch install on this Windows host does **not** currently reach a
usable state. Whether that is host-local or general is exactly what the
registry experiment settles. Until it is settled, "Windows works" is unproven
for the build being considered for promotion — and the last Windows evidence in
the ledger is against the *published* 0.4.260810.1, not this tree.
