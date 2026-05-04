---
tags: [wsl, wsl2, browser-isolation, chromium, sandbox, hardening, proxy, nftables, selinux, windows]
languages: []
since: 2026-04-28
last_verified: 2026-04-28
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/wsl-config
  - https://learn.microsoft.com/en-us/windows/wsl/tutorials/gui-apps
  - https://chromium.googlesource.com/chromium/src/+/HEAD/docs/linux/sandboxing.md
  - https://chromium.googlesource.com/chromium/src/+/HEAD/headless/README.md
  - https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md
  - https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
  - https://man7.org/linux/man-pages/man7/capabilities.7.html
  - https://wiki.nftables.org/wiki-nftables/index.php/Configuring_chains
  - https://docs.fedoraproject.org/en-US/quick-docs/selinux-getting-started/
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: true
pull_recipe: see-section-pull-on-demand
---

# WSL browser isolation (Chromium)

@trace spec:agent-cheatsheets, spec:cross-platform, spec:windows-wsl-runtime, spec:chromium-browser-isolation

**Version baseline**: WSL2 on Windows 10 build 19044+ / Windows 11; systemd integration requires Win 10 19044+ or Win 11 22H2+.
**Use when**: hosting a hardened Chromium browser as a sibling WSL distro alongside `tillandsias-forge`/`tillandsias-git`/`tillandsias-proxy`/etc. Goal: full filesystem + credential isolation from the host, all egress forced through `tillandsias-proxy:3128`. The Windows arm of `spec:chromium-browser-isolation`.

## Provenance

- <https://learn.microsoft.com/en-us/windows/wsl/wsl-config> — `/etc/wsl.conf` per-distro semantics; `[automount]`, `[boot]`, `[interop]` sections
- <https://learn.microsoft.com/en-us/windows/wsl/tutorials/gui-apps> — WSLg GPU/Wayland passthrough via `/dev/dxg` and `/usr/lib/wsl`
- <https://chromium.googlesource.com/chromium/src/+/HEAD/docs/linux/sandboxing.md> — Chromium sandbox: namespace + seccomp-bpf, kernel requirements
- <https://chromium.googlesource.com/chromium/src/+/HEAD/headless/README.md> — `--headless=new` semantics post-M132 (legacy moved to `chrome-headless-shell`)
- <https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md> — `--proxy-server`, `--proxy-bypass-list` syntax
- <https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html> — hardening directives (`NoNewPrivileges`, `ProtectHome`, etc.)
- <https://man7.org/linux/man-pages/man7/capabilities.7.html> — capability bounding set semantics
- <https://wiki.nftables.org/wiki-nftables/index.php/Configuring_chains> — chain `policy drop` + accept-rule pattern
- <https://docs.fedoraproject.org/en-US/quick-docs/selinux-getting-started/> — Fedora's targeted SELinux, custom `.te` modules
- **Last updated:** 2026-04-28

## Why a sibling WSL distro vs Windows Sandbox

This distro is the Windows arm of `spec:chromium-browser-isolation`. Windows Sandbox was investigated and rejected as the primary mechanism (see `runtime/windows-sandbox.md` for the full feasibility report — kept as a "considered, rejected" alternative per the @trace lifecycle convention). The blockers: Sandbox is unavailable on Windows Home, has no middle-ground network mode (all-or-nothing), no CDP attach across the boundary, multi-instance is Win11 24H2+ only. A WSL distro sibling avoids every one of those. Trade-off: WSL2 has one shared Linux kernel for all distros; Sandbox spawns a per-instance kernel. We already accept the shared-kernel trust model for the forge distro (where untrusted agent code runs); this cheatsheet adds a more-locked-down distro alongside.

## Isolation properties achieved

| Property | Mechanism | Citation |
|---|---|---|
| Separate filesystem from host | `/etc/wsl.conf` `[automount] enabled=false` removes `/mnt/c`; the distro's `ext4.vhdx` is the only filesystem | Microsoft Learn |
| Separate process namespace | Each WSL distro has its own PID 1 and process tree | Microsoft Learn |
| Separate user / no host credentials | Browser runs as in-distro `chrome` user (uid=1000); no `/mnt/c` ⇒ no Windows Credential Manager visibility; `[interop] enabled=false` removes the host-DBus bridge | Microsoft Learn |
| Chromium internal sandbox | `--enable-sandbox` (default) → unprivileged user namespaces + seccomp-bpf; works in WSL2 because `kernel.unprivileged_userns_clone=1` is the kernel default | chromium.googlesource.com/.../sandboxing.md |
| Capability drop | systemd `CapabilityBoundingSet=` empties the inheritable cap set on the service unit; `setcap -r` strips file caps from the binary | capabilities(7) |
| systemd hardening | `NoNewPrivileges=true`, `ProtectHome=true`, `ProtectSystem=strict`, `PrivateTmp=true`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`, `RestrictNamespaces=true`, `LockPersonality=true` | systemd.exec(5) |
| SELinux confinement | Fedora targeted policy + a small `chromium_browser.te` module restricting Chromium to its own type | Fedora Project docs |
| Egress fence | nftables `output` chain with `policy drop` + a single accept rule for the proxy address; loopback exempt for CDP | nftables.org wiki |
| Force-proxy | Chromium `--proxy-server=http://tillandsias-proxy:3128 --proxy-bypass-list="<-loopback>"`; `HTTP_PROXY`/`HTTPS_PROXY` env as belt-and-braces | net/docs/proxy.md |
| Per-project allowlist | Squid in `tillandsias-proxy` already enforces this; each project gets its own ACL | (existing infra) |
| Truly headless if needed | `--headless=new` (M132+) | headless/README.md |
| CDP attach from host | `--remote-debugging-port=9222` on loopback; mirrored WSL networking exposes it to the host's loopback | net/docs/proxy.md + Microsoft Learn |
| Ephemeral state | `tmpfs` mount for `/home/chrome` and `/tmp`; `wsl --terminate` discards the running VM, `wsl --unregister` discards the vhdx | (existing infra) |

## Recipe — `/etc/wsl.conf`

```ini
[automount]
enabled = false
mountFsTab = false

[interop]
enabled = false
appendWindowsPath = false

[boot]
systemd = true
command = /usr/sbin/nft -f /etc/nftables.conf

[user]
default = chrome

[network]
hostname = tillandsias-browser-chrome
```

`[interop] enabled = false` is the load-bearing switch for credential isolation: it removes the binary that translates Linux→Windows IPC. Without it, even with `/mnt/c` gone, a determined process could still execute Windows binaries over the WSL interop pipe.

## Recipe — Chromium command-line flags

```bash
chromium-browser \
  --enable-sandbox \
  --disable-dev-shm-usage \
  --proxy-server="http://tillandsias-proxy:3128" \
  --proxy-bypass-list="<-loopback>;127.0.0.1;localhost" \
  --no-default-browser-check \
  --no-first-run \
  --disable-component-update \
  --disable-features=TranslateUI,InterestFeedContentSuggestions \
  --user-data-dir=/home/chrome/data \
  --remote-debugging-port=9222 \
  --remote-debugging-address=127.0.0.1
```

For headless Playwright/CDP automation, add `--headless=new`. Modern headless still uses the full renderer; if you need a truly stripped headless path, use the standalone `chrome-headless-shell` binary (M118+, see headless/README.md).

`--proxy-bypass-list="<-loopback>;..."` is the documented incantation that re-enables proxying for `localhost`/`127.0.0.1` (the default behaviour proxies-bypass loopback). For Tillandsias the CDP port is on loopback, so we want to bypass-the-bypass for those targets specifically — actually the default bypasses loopback already, so the only reason to set this list is if you ALSO want to allow some intra-distro hostnames. Default is fine for most Tillandsias setups; including the line above documents intent.

## Recipe — systemd unit (`/etc/systemd/system/chromium.service`)

```ini
[Unit]
Description=Tillandsias Chromium (isolated)
After=nftables.service network-online.target
Wants=nftables.service

[Service]
Type=simple
User=chrome
Group=chrome
WorkingDirectory=/home/chrome
ExecStart=/usr/bin/chromium-browser \
  --enable-sandbox \
  --disable-dev-shm-usage \
  --proxy-server=http://tillandsias-proxy:3128 \
  --no-default-browser-check --no-first-run \
  --disable-component-update \
  --user-data-dir=/home/chrome/data \
  --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1

# Hardening (per systemd.exec(5))
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
PrivateTmp=true
PrivateDevices=false                # Chromium needs /dev/dxg (WSLg) and /dev/snd
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=true
LockPersonality=true
ReadOnlyPaths=/etc /usr /boot /lib
ReadWritePaths=/home/chrome /tmp /run

# DO NOT enable MemoryDenyWriteExecute — V8 JIT requires writable+executable
# pages. Setting MemoryDenyWriteExecute=true crashes Chromium at startup.
# Documented incompatibility (see Pitfalls below).

# CapabilityBoundingSet= (empty) drops every capability after exec.
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
```

## Recipe — nftables egress fence (`/etc/nftables.conf`)

```nft
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain output {
    type filter hook output priority 0; policy drop;

    # Loopback (CDP, DNS via systemd-resolved on 127.0.0.53)
    oifname "lo" accept

    # The proxy. Replace with the resolved address of tillandsias-proxy
    # under WSL2 mirrored networking (a 192.168.x.y in the host LAN range).
    ip daddr <tillandsias-proxy-IP> tcp dport 3128 accept

    # Everything else is denied.
  }
}
```

Persistence at distro boot is wired via the `[boot] command =` line in `/etc/wsl.conf` (above). Once systemd is up, the `nftables.service` will reload the same file from `/etc/nftables.conf` — belt-and-suspenders.

## Recipe — Chromium SELinux module (`chromium_browser.te`)

Minimum policy that lets Chromium run under its own confined type without leaking access to other process spaces:

```selinux
policy_module(chromium_browser, 1.0.0)

require {
  type init_t;
  type bin_t;
  attribute domain;
}

type chromium_browser_t, domain;
type chromium_browser_exec_t;

init_daemon_domain(chromium_browser_t, chromium_browser_exec_t)
allow chromium_browser_t self:capability { setuid setgid };  # for the namespace sandbox
allow chromium_browser_t self:user_namespace { create };
```

Compile and load: `make -f /usr/share/selinux/devel/Makefile chromium_browser.pp && semodule -i chromium_browser.pp`. After install: `restorecon -v /usr/bin/chromium-browser`.

If your build of Fedora-minimal isn't shipping a SELinux policy at all, run with SELinux in permissive mode and rely on capabilities + nftables + Chromium's internal sandbox as the primary defences. SELinux is additive; the absence of a custom policy doesn't disable the layers above.

## GPU / WSLg

WSLg ships an `/usr/lib/wsl` library overlay and `/dev/dxg` para-virtualised GPU device. Chromium picks these up automatically. Tested working flags:

```bash
--use-gl=egl --use-angle=d3d11
```

Headless rendering on a host without WSLg or without a vGPU driver falls back to software rendering (slower, no crash). To force software rendering for reproducibility:

```bash
--use-angle=swiftshader
```

## Common pitfalls

- **`MemoryDenyWriteExecute=true` crashes Chromium.** V8's JIT requires regions mappable as both `PROT_WRITE` and `PROT_EXEC`. Setting `MemoryDenyWriteExecute=true` in the service unit will trigger an immediate crash at first JS execution. Documented incompatibility — known to PHP and others; same root cause. **Never set it.**
- **Don't use `--no-sandbox`.** It disables Chromium's namespace + seccomp-bpf protection. The sandbox works fine in WSL2 because `unprivileged_userns_clone` is the kernel default; if you ever see "namespace sandbox failed", investigate (likely a SELinux or LSM block), don't disable.
- **`ct state established,related` may misbehave on the WSL2 kernel.** Conntrack state-matching has known limitations under WSL2 (Microsoft/WSL#6655). Prefer the simple `ip daddr X tcp dport Y accept` rule pattern shown above; only add `ct state` if the simple rule isn't enough AND tests pass.
- **`--headless=old` was REMOVED in M132.** Legacy headless (the historic Puppeteer target) is now a separate `chrome-headless-shell` binary. If you depend on `--headless=old`, switch to `--headless=new` and audit any tests that relied on the old renderer's quirks.
- **Default `--proxy-bypass-list` excludes loopback.** Chromium documents that `localhost`/`127.0.0.1` bypass the proxy unless you pass `<-loopback>` in the bypass list. For Tillandsias this is what you want (CDP needs to reach loopback without proxying). Don't override unless intentional.
- **WSL1 cannot run Chromium's namespace sandbox.** WSL1 has no kernel namespace support. The cheatsheet assumes WSL2; if a user's distro defaulted to WSL1, `wsl --set-version <distro> 2` is the fix. Tillandsias' init flow imports as v2 by passing `--version 2` to `wsl --import`.
- **`ProtectHome=true` breaks `/home/chrome` writes.** The Chromium service unit needs `/home/chrome` writable for the user-data-dir. Use `ReadWritePaths=/home/chrome` to override `ProtectHome=true`'s read-only treatment for that path specifically.
- **`PrivateDevices=true` removes `/dev/dxg`.** That kills WSLg GPU acceleration. For a GPU-using browser, leave `PrivateDevices=false` (default) and rely on capability drops + namespace sandbox.
- **`--user-data-dir` defaults outside `/home/chrome`.** If you don't pass `--user-data-dir`, Chromium falls back to `~/.config/chromium`, which on a fresh distro might not exist or may end up under a path your hardening blocks. Always set it explicitly.
- **DNS lookups bypassing nftables.** systemd-resolved on `127.0.0.53` is allowed by the loopback rule; if you instead use `/etc/resolv.conf` pointing at `8.8.8.8`, the `policy drop` will block DNS and nothing resolves. Either keep systemd-resolved or add a `udp dport 53` rule for an internal DNS allowed by the proxy.

## Tillandsias integration sketch

```text
tray (Rust)
  └─ tray_spawn::spawn_browser_window(project, session_id)
      ├─ Stage chromium tarball + .wsl-build/build-browser-chrome.sh
      │     under %LOCALAPPDATA%\tillandsias\WSL\browser-chrome\
      ├─ wsl --import tillandsias-browser-chrome <install-dir> <tar> --version 2
      │     (idempotent — pre-delete ext4.vhdx per init.rs::wsl-import recipe)
      ├─ Bake-in /etc/wsl.conf, /etc/nftables.conf, systemd unit, SELinux .pp
      ├─ Set HTTP_PROXY/HTTPS_PROXY env on the launched Chromium process
      ├─ Track distro-name ⇄ session_id mapping in tray state
      └─ On project close:
            wsl --terminate tillandsias-browser-chrome-<project>
            (or --unregister for a full wipe of vhdx + state)
```

CDP attach from the host runs against `127.0.0.1:9222` directly — under WSL2 mirrored networking the loopback inside the distro IS the host loopback (we landed mirrored mode in `0.1.184.545`).

## See also

- `runtime/windows-sandbox.md` — considered/rejected alternative; preserved per @trace lifecycle for the rationale trail
- `runtime/wsl-on-windows.md` — sibling architectural pattern (forge/git/proxy/router/inference distros)
- `runtime/wsl-mount-points.md` — drvfs ownership semantics that DON'T apply when `/mnt/c` is disabled
- `runtime/wsl-daemon-patterns.md` — long-running services in WSL, systemd in WSL specifics
- `runtime/secrets-management.md` — credential isolation rationale
- `runtime/podman-security-flags.md` (planned) — sibling Linux backend for the same `chromium-browser-isolation` spec

## Pull on Demand

### Source

This cheatsheet documents hardened Chromium deployment in a WSL2 distro alongside the main forge distro, with nftables egress filtering, SELinux hardening, systemd unit isolation, and CDP debugging support.

### Materialize recipe

```bash
#!/bin/bash
# Build WSL2 browser-chrome distro with Chromium hardening
# @trace spec:chromium-browser-isolation, spec:windows-wsl-runtime

# Build base distro from fedora-minimal:44 + Chromium + hardening tools
podman create registry.fedoraproject.org/fedora-minimal:44 /bin/sh -c 'true' > "$BUILD_CONTAINER"

# Layer 1: install Chromium + nftables + SELinux tools
podman exec --user root "$BUILD_CONTAINER" microdnf install -y \
    chromium \
    nftables selinux-policy selinux-policy-devel \
    systemd \
    --setopt=install_weak_deps=False

# Layer 2: create browser user with restricted capabilities
podman exec --user root "$BUILD_CONTAINER" /bin/sh -c '
  useradd -u 1000 -m -s /bin/bash chromium
  usermod --add-subuids 100000-165535 chromium
  usermod --add-subgids 100000-165535 chromium
'

# Layer 3: ship hardened wsl.conf and nftables.conf
podman cp images/browser-chrome/wsl.conf "$BUILD_CONTAINER:/etc/wsl.conf"
podman cp images/browser-chrome/nftables.conf "$BUILD_CONTAINER:/etc/nftables.conf"

# Export to tarball for wsl --import
podman export "$BUILD_CONTAINER" -o "target/wsl/tillandsias-browser-chrome.tar"
```

### Generation guidelines

This cheatsheet is hand-curated and tracked in-repo. Regenerate after:
1. Chromium changes to sandbox or headless mode
2. WSL2 adds new wsl.conf keys
3. WSL2 kernel changes nftables feature support
4. Fedora's SELinux policy or tools update

### License

License: CC-BY-4.0 (https://creativecommons.org/licenses/by/4.0/) Content derived from Microsoft Learn, Chromium upstream documentation, freedesktop.org, kernel.org, and Fedora Project sources.
Last materialized: 2026-05-03
