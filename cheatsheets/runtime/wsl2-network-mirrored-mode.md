---
tags: [windows, wsl2, networking, mirrored, nat, hyper-v-firewall, dns-tunneling, autoproxy, hostaddressloopback, ignoredports, podman-bridge]
languages: [powershell, bash]
since: 2026-04-28
last_verified: 2026-04-28
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/networking
  - https://learn.microsoft.com/en-us/windows/wsl/wsl-config
  - https://learn.microsoft.com/en-us/windows/wsl/troubleshooting
  - https://docs.podman.io/en/latest/markdown/podman-network.1.html
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: true
pull_recipe: see-section-pull-on-demand
---

# WSL2 networking — mirrored mode under the new architecture

@trace spec:agent-cheatsheets, spec:cross-platform, spec:windows-wsl-runtime, spec:enclave-network, spec:git-mirror-service

**Version baseline**: WSL ≥ 2.0.0 + Windows 11 22H2+ for mirrored mode; mirrored matures continuously since 2023.
**Use when**: deciding the WSL networking mode under the `WindowsHost > tray + ONE WSL distro > podman > containers` architecture; reasoning about how Windows-tray ↔ WSL-VM ↔ podman-container traffic flows in BOTH directions; debugging "why can't the tray reach localhost:14000".

## Provenance

- <https://learn.microsoft.com/en-us/windows/wsl/networking> — NAT vs mirrored; full feature list of mirrored mode
- <https://learn.microsoft.com/en-us/windows/wsl/wsl-config> — `[wsl2] networkingMode`, `firewall`, `dnsTunneling`, `autoProxy`, `localhostForwarding`; `[experimental] hostAddressLoopback`, `ignoredPorts`
- <https://learn.microsoft.com/en-us/windows/wsl/troubleshooting> — networking mode-specific troubleshooting (Hyper-V firewall, DNS, IPv6)
- <https://docs.podman.io/en/latest/markdown/podman-network.1.html> — podman bridge networks layered inside the WSL VM
- **Last updated:** 2026-04-28

## The choice and why

WSL2 supports five networking values per `wsl-config`:

> "Available values are: `none`, `nat`, `bridged` (deprecated), `mirrored`, and `virtioproxy`."

Tillandsias picks **mirrored**. The architectural reason is dictated by the bidirectional reachability we need:

| Direction | Required by | Mirrored | NAT |
|---|---|---|---|
| Windows tray → `localhost:14000` (router) → opencode-web in podman container | tray UX | direct: WSL `127.0.0.1:14000` IS Windows `127.0.0.1:14000` | requires `localhostForwarding=true` (default) |
| Container → container via service name (`git push origin` resolves `git-service`) | spec:git-mirror-service transparent invariant | works (podman bridge inside the VM is independent of WSL mode) | works (same — podman bridge is unchanged by WSL mode) |
| Forge container → Windows host services | NEVER (forge attaches to `--internal` network) | not exposed | not exposed |
| External LAN → WSL services | tray-only deployment doesn't need this | possible if Hyper-V firewall allows | NAT'd |
| IPv6 | future-proofing for upstream services | yes | NO |
| VPN compatibility | corporate users | yes | flaky |

Per `learn.microsoft.com/networking` the mirrored-mode benefit list (verbatim):

> "IPv6 support; Connect to Windows servers from within Linux using the localhost address `127.0.0.1`. IPv6 localhost address `::1` is not supported; Improved networking compatibility for VPNs; Multicast support; Connect to WSL directly from your local area network (LAN)."

For Tillandsias the third benefit (VPN compat) and the first/second (the bidirectional `127.0.0.1` reflection) are the load-bearing reasons.

## What mirrored does (and doesn't)

Mirrored mode mirrors **the host's network interfaces into Linux**. Per `wsl-config`:

> "On machines running Windows 11 22H2 and higher you can set `networkingMode=mirrored` under `[wsl2]` in the `.wslconfig` file to enable mirrored mode networking. Enabling this changes WSL to an entirely new networking architecture which has the goal of 'mirroring' the network interfaces that you have on Windows into Linux …"

Practically:

- The WSL VM and Windows host share the **same set of NICs** (logically). `ip addr` inside the VM shows the same interfaces as `ipconfig` on Windows.
- WSL's `127.0.0.1` and Windows' `127.0.0.1` are **the same loopback** for routing purposes — connections to `127.0.0.1:N` from either side reach the listener on either side.
- Only IPv4 loopback. Per the verbatim quote above, *"IPv6 localhost address `::1` is not supported"*. Bind your tray-served services to `127.0.0.1` (IPv4) explicitly, not `::1`.
- **Mirrored does NOT mirror the distros' bridges** — it mirrors HOST interfaces. The podman bridge inside the distro stays internal to the WSL VM (which is what we want for service-to-service traffic).

## What mirrored does NOT change

The choice of WSL networking mode is **orthogonal** to the podman-internal network design. Inside the distro, podman creates its own `bridge` network (`tillandsias-enclave`) on `10.89.0.0/24`; container-to-container traffic stays on that bridge, kernel-routed, never touches the WSL boundary.

The mode changes ONLY:
- How Windows reaches services published with `podman run -p`.
- How the WSL distro reaches Windows services (we don't need this — forge is `--internal`).
- Whether the LAN can reach WSL services (Hyper-V firewall gates this).

## The recommended `.wslconfig` block

```ini
# @trace spec:windows-wsl-runtime, spec:enclave-network, spec:cross-platform
# @cheatsheet runtime/wsl2-network-mirrored-mode.md

[wsl2]
networkingMode = mirrored        # this cheatsheet's whole topic

# Hyper-V firewall: KEEP enabled. It applies the host's Windows Firewall rules
# to traffic in/out of the WSL VM. Disabling exposes WSL services to the LAN.
# Per `wsl-config`: "Setting this to true allows the Windows Firewall rules,
# as well as rules specific to Hyper-V traffic, to filter WSL network traffic."
firewall = true

# DNS tunneling: keep on. Resolution goes through a virtio channel rather
# than packet-based; works with `[network] generateResolvConf=false` because
# the tunnel writes /etc/resolv.conf for us.
# Per `wsl-config`: "On machines running Windows 11 22H2 and higher the
# dnsTunneling feature is on by default … it uses a virtualization feature
# to answer DNS requests from within WSL, instead of requesting them over
# a networking packet."
dnsTunneling = true

# AutoProxy: OFF. This honoring of Windows WPAD/manual-proxy settings would
# silently route forge container egress through the user's corporate proxy.
# We manage proxy in-enclave (via tillandsias-proxy + Squid allowlist).
autoProxy = false

# Loopback forwarding (NAT-only flag): noop under mirrored, harmless to set.
localhostForwarding = true       # belt-and-suspenders for users who fall back to NAT

[experimental]
# hostAddressLoopback: when true, containers in the VM can connect to the
# Windows host by an IP assigned to the host. We DON'T want this in production
# (forge containers are --internal), but the tray's smoke-test path uses it.
# Per `wsl-config`: "Only applicable when `wsl2.networkingMode` is set to
# `mirrored`. When set to `true`, will allow the Container to connect to the
# Host, or the Host to connect to the Container, by an IP address that's
# assigned to the Host."
hostAddressLoopback = false      # default; explicit-false documents intent

# ignoredPorts: ports the WSL Linux side may bind to even if Windows already
# uses them. Use sparingly. We don't need any in MVP.
# Per `wsl-config`: "Only applicable when `wsl2.networkingMode` is set to
# `mirrored`. Specifies which ports Linux applications can bind to, even if
# that port is used in Windows."
# ignoredPorts =
```

## Port publishing — Windows tray reaches a podman container

Path under mirrored:

```
Windows tray
  ↓ (HTTP GET to http://localhost:14000/<session>)
Windows 127.0.0.1:14000        ←── mirrored ───▶ WSL VM 127.0.0.1:14000
  ↑                                              ↓
  reflected from VM                              published by podman -p
                                                 ↓
                                          tillandsias-router container
                                          listening on its eth0 :4096
                                                 ↓
                                          caddy → opencode-web upstream
```

The `podman run -p 127.0.0.1:14000:4096 …` binding is on the WSL VM's loopback, which mirrored mode reflects bidirectionally to Windows' loopback. **Always bind to `127.0.0.1`, not `0.0.0.0`** — `0.0.0.0` would expose the published port to the LAN even with Hyper-V firewall enabled (the firewall rules apply to inbound from outside, not internal binds).

## Container → container — independent of WSL mode

Inside the distro, podman runs aardvark-dns alongside netavark. When the forge container does `git push origin` (where origin = `git://git-service:9418/<project>`):

```
forge container's /etc/resolv.conf points at aardvark-dns (10.89.0.1)
  ↓
aardvark-dns answers "git-service" → 10.89.0.5 (the git container's IP on tillandsias-enclave)
  ↓
TCP SYN over the bridge interface to 10.89.0.5:9418
  ↓
git container's git-daemon receives, reads from /var/lib/git-mirror/<project>.git
  ↓
post-receive hook fires, pushes to GitHub via the proxy container
```

None of this hits the WSL boundary. The transparent `git push origin` invariant Tillandsias requires (no agent-side direction) holds **regardless of NAT vs mirrored** for the WSL outer mode — it's purely a function of the podman-internal bridge + aardvark-dns.

## DNS resolution — three layers

1. **Container-internal DNS** — aardvark-dns answers podman-bridge service names (`git-service`, `proxy`, `inference`). Already covered above.
2. **Distro-internal DNS** — `/etc/resolv.conf` inside the distro. With `[network] generateResolvConf=false` (per `runtime/wsl2-isolation-boundary.md`), Tillandsias ships a static `/etc/resolv.conf` pointing at the proxy container or upstream resolvers. With `dnsTunneling=true`, Microsoft's virtio channel keeps resolution working without packet-based DNS — useful when network is being reconfigured.
3. **Windows-host DNS** — handled by Windows; the WSL VM uses Windows' resolver via the virtio tunnel when `dnsTunneling=true`.

For the proxy container (which DOES need external DNS to reach the allowlist's destinations), it falls back to Windows-host DNS via dnsTunneling. The proxy then answers internal containers via its own forwarder.

## Mirrored mode caveats

Per `learn.microsoft.com/networking` and `troubleshooting`:

- **Requires Windows 11 22H2 or higher.** Older builds silently fall back to NAT. Tillandsias' `windows-installer-prereqs.md` already requires 22H2+ for the new architecture.
- **`::1` (IPv6 loopback) NOT supported.** Bind tray-served services to `127.0.0.1` explicitly. If you need IPv6 outbound, mirrored DOES support it; only loopback is IPv4-only.
- **Hyper-V firewall is ON by default and SHOULD stay ON.** Disabling exposes published ports to the LAN. Tillandsias' `.wslconfig` keeps it on.
- **No `bridged` mode** — that's deprecated per `wsl-config`. Don't use it.
- **`hostAddressLoopback` is mirrored-only.** The flag is documented at `wsl-config` but only takes effect under mirrored. Setting it under NAT is silently ignored.

## NAT mode — what we'd lose if we fall back

If a user is on Win 10 19044+ (no mirrored support), the distro silently falls back to NAT. Differences for the user:

- **Tray reachability** — `localhost:14000` still works via `localhostForwarding=true` (NAT default). UX-equivalent.
- **No IPv6** for inbound from LAN. Negligible for tray-only Tillandsias.
- **VPN compat** is poor under NAT. Corporate users on VPNs may see DNS issues; recommend mirrored-capable Windows 11.
- **Mirrored-specific keys** (`hostAddressLoopback`, `ignoredPorts`) are no-ops.

## Hyper-V firewall — what to know

Per `wsl-config`:

> "Setting this to true allows the Windows Firewall rules, as well as rules specific to Hyper-V traffic, to filter WSL network traffic."

The Hyper-V firewall is a Windows Firewall extension that applies host-side Windows Firewall rules to the WSL VM's network adapter. By default it's enabled (Win 11 22H2+ adds it explicitly). For Tillandsias:

- **Inbound from LAN**: blocked unless an explicit Windows Firewall rule allows it. Tillandsias publishes only to `127.0.0.1`, so LAN inbound never hits the rules.
- **Outbound from WSL**: applies host-side outbound rules. If the user has aggressive outbound restrictions, they may need to allow the WSL VM's NIC.
- **Mirrored-specific rules**: Windows 11 24H2+ supports per-WSL-VM Hyper-V firewall rule scoping; older builds apply host rules wholesale.

**Don't disable** — `firewall=false` is documented at `wsl-config` but its effect is *exposing* the WSL VM to the LAN, not relaxing internal Tillandsias traffic.

## Common pitfalls

- **Mirrored falls back to NAT silently** on Win 10 / pre-22H2 Win 11 — `wsl --status` doesn't tell you which mode is active. Verify via `ip addr` inside the VM (mirrored shows the same interfaces as Windows; NAT shows a single `eth0` with a 172.x.x.x).
- **`::1` listeners DON'T reach Windows from the VM** under mirrored. Bind to `127.0.0.1` (IPv4) explicitly.
- **Windows Firewall rule changes** require a `wsl --shutdown` to re-read. The Hyper-V firewall caches state per VM lifecycle.
- **Auto-proxy on at the Windows side** — corporate machines typically have WPAD or manual proxy. With `autoProxy=true`, WSL inherits this and routes ALL container egress through the corporate proxy. Tillandsias sets `autoProxy=false` so our enclave proxy is the only egress path.
- **Mirrored + `[interop] enabled=false`** is a working combination, but some `localhostForwarding` legacy paths assume interop is on. Tillandsias' interop=false is fine because we're under mirrored, but be aware mixing modes can surprise.
- **Multicast** under mirrored works; under NAT it doesn't. Tillandsias has no multicast use case but document it.
- **Container-to-VM traffic uses cni/netavark** — the choice of NAT vs mirrored doesn't affect it. Don't tune mirrored when you mean to tune the podman bridge.

## Verification

```powershell
# Mirrored mode active?
wsl -d tillandsias -- ip -4 addr show
# Expected: same interfaces as `ipconfig /all` on Windows (mirrored)
# vs: a single eth0 with 172.x.x.x (NAT fallback)

# Hyper-V firewall on?
Get-NetFirewallHyperVProfile
# Expected: Enabled = True

# DNS tunneling working? (won't show packets in Wireshark on Windows-side)
wsl -d tillandsias -- nslookup github.com
# Expected: returns; no packets visible on Windows host's NIC

# Tray ↔ podman publish path:
wsl -d tillandsias --user root -- podman run --rm -d -p 127.0.0.1:14000:4096 --name probe nginx
# Then on Windows:
curl http://localhost:14000/
# Expected: nginx welcome page
wsl -d tillandsias --user root -- podman rm -f probe
```

## See also

- `runtime/wsl2-isolation-boundary.md` — the rest of `.wslconfig` keys (the full hardening profile)
- `runtime/podman-in-wsl2.md` — podman-internal networking (pasta vs bridge, aardvark-dns) — independent of mirrored
- `runtime/fedora-minimal-wsl2.md` — the distro that hosts the podman bridge
- `runtime/wsl-on-windows.md` — `wsl --exec` mechanics; tied to networking via the relay model
- `runtime/networking.md` — agent-facing reference inside the forge for the proxy/git-service/inference allowlist
- `docs/cheatsheets/runtime/wsl/networking-modes.md` — the longer-form maintainer's reference; this cheatsheet is the agent-facing condensation

## Pull on Demand

> Hand-curated, tracked in-repo (`committed_for_project: true`).
> Provenance: vendor primary sources only (Microsoft Learn, docs.podman.io).
> Refresh cadence: when WSL ships a new networking mode (e.g. virtioproxy
> graduates from `[experimental]`), when Microsoft documents new
> mirrored-only keys, or when the Hyper-V firewall semantics change in a
> Windows feature update.
