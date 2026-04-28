---
tags: [wsl, wsl2, networking, nat, mirrored, hyper-v-firewall, dns-tunneling]
languages: []
since: 2026-04-26
last_verified: 2026-04-26
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/networking
  - https://learn.microsoft.com/en-us/windows/wsl/wsl-config
authority: high
status: current
---

# WSL2 networking modes

@trace spec:cross-platform, spec:enclave-network
@cheatsheet runtime/wsl/architecture-isolation.md

## Provenance

- "Accessing network applications with WSL" — <https://learn.microsoft.com/en-us/windows/wsl/networking> — fetched 2026-04-26. Page `ms.date: 2024-07-16`, `updated_at: 2025-12-09`.

  > "By default WSL uses a NAT based architecture, and we recommend trying the new Mirrored networking mode to get the latest features and improvements."

  > "If you are building a networking app (for example an app running on a NodeJS or SQL server) in your Linux distribution, you can access it from a Windows app (like your Edge or Chrome internet browser) using `localhost` (just like you normally would)."

  > "If you want to access a networking app running on Windows (for example an app running on a NodeJS or SQL server) from your Linux distribution (ie Ubuntu), then you need to use the IP address of your host machine."

  > "When using a WSL 1 distribution, if your computer was set up to be accessed by your LAN, then applications run in WSL could be accessed on your LAN as well. This isn't the default case in WSL 2. WSL 2 has a virtualized ethernet adapter with its own unique IP address."

  Mirrored mode benefits (verbatim):

  > "On machines running Windows 11 22H2 and higher you can set `networkingMode=mirrored` under `[wsl2]` in the `.wslconfig` file to enable mirrored mode networking. Enabling this changes WSL to an entirely new networking architecture which has the goal of 'mirroring' the network interfaces that you have on Windows into Linux, to add new networking features and improve compatibility.
  >
  > Here are the current benefits to enabling this mode:
  > - IPv6 support
  > - Connect to Windows servers from within Linux using the localhost address `127.0.0.1`. IPv6 localhost address `::1` is not supported
  > - Improved networking compatibility for VPNs
  > - Multicast support
  > - Connect to WSL directly from your local area network (LAN)"

  > "On machines running Windows 11 22H2 and higher the `dnsTunneling` feature is on by default (which can be found under `[wsl2]` in the `.wslconfig` file) and it uses a virtualization feature to answer DNS requests from within WSL, instead of requesting them over a networking packet. This feature is aimed to improve compatibility with VPNs, and other complex networking set ups."

  > "On machines running Windows 11 22H2 and higher, setting `autoProxy=true` under `[wsl2]` in the `.wslconfig` file enforces WSL to use Windows' HTTP proxy information."

  > "On machines running Windows 11 22H2 and higher, with WSL 2.0.9 and higher, the Hyper-V firewall feature will be turned on by default."

- `.wslconfig` networking keys — <https://learn.microsoft.com/en-us/windows/wsl/wsl-config> — fetched 2026-04-26. Page `ms.date: 2025-07-31`, `updated_at: 2025-12-09`.

  > "`networkingMode` … Available values are: `none`, `nat`, `bridged` (deprecated), `mirrored`, and `virtioproxy`. If the value is `none`, the WSL network is disconnected. If the value is `nat` or an unknown value, NAT network mode is used (starting from WSL 2.3.25, if NAT network mode fails, it falls back to using VirtioProxy network mode). If the value is `bridged`, the bridged network mode is used (this mode has been marked as deprecated since WSL 2.4.5). If the value is `mirrored`, the mirrored network mode is used."

  > "`firewall` … Setting this to true allows the Windows Firewall rules, as well as rules specific to Hyper-V traffic, to filter WSL network traffic."

  > "`localhostForwarding` … Boolean specifying if ports bound to wildcard or localhost in the WSL 2 VM should be connectable from the host via `localhost:port`."

  Mirrored-mode experimental knobs (verbatim):

  > "`ignoredPorts` … Only applicable when `wsl2.networkingMode` is set to `mirrored`. Specifies which ports Linux applications can bind to, even if that port is used in Windows."

  > "`hostAddressLoopback` … Only applicable when `wsl2.networkingMode` is set to `mirrored`. When set to `true`, will allow the Container to connect to the Host, or the Host to connect to the Container, by an IP address that's assigned to the Host."

- **Last updated**: 2026-04-26

**Use when**: deciding how to expose enclave services to the Windows host, debugging localhost forwarding, planning a port publish strategy.

## Quick reference

| Mode | Default? | Loopback host ↔ WSL | LAN ↔ WSL | IPv6 | DNS |
|---|---|---|---|---|---|
| `nat` | yes | localhost forwarding (proxy via gvproxy-ish helper) | requires `netsh portproxy` | no | DNS proxy via NAT host (`dnsProxy=true` default) |
| `mirrored` | opt-in (Win11 22H2+) | both directions on `127.0.0.1` | yes | yes | DNS tunneling via virtio (default on) |
| `bridged` | deprecated | n/a | n/a | n/a | n/a |
| `none` | opt-in | none | none | none | none |
| `virtioproxy` | fallback | proxy via virtio | n/a | n/a | n/a |

| Knob | Default | What it does |
|---|---|---|
| `localhostForwarding` | `true` | NAT-mode only — auto-binds Linux-listened ports to Windows `localhost:<port>` |
| `dnsTunneling` | `true` (Win11 22H2+) | Resolves DNS through Windows DNS resolver (helps VPNs) |
| `autoProxy` | `true` (Win11 22H2+) | Reads Windows HTTP proxy and exports to Linux env |
| `firewall` | `true` (Win11 22H2+, WSL ≥2.0.9) | Hyper-V firewall filters WSL traffic |

## Implications for Tillandsias

| Concern | NAT mode | Mirrored mode |
|---|---|---|
| Tray on host reaches forge in WSL | yes (auto via `localhostForwarding`) | yes (`127.0.0.1` works directly) |
| Forge in WSL reaches host (e.g., MCP server on host) | only via host gateway IP (`ip route show default`) | yes (`127.0.0.1`) |
| Two distros isolated by network namespace | **no** (default; they share the same namespace — see `architecture-isolation.md`) | **no** (mirrored mode mirrors host interfaces; distros still share) |
| IPv6-only services | broken | works |
| Hyper-V firewall blocks inbound from LAN | yes (default deny) | yes (configurable per-rule) |
| WSL listens on a Windows-bound port | port collision possible | use `ignoredPorts` to allow same-port binding |
| `--add-host alias:host-gateway` works (current Tillandsias workaround) | yes — that's the runtime today | yes, but `127.0.0.1` is also viable |

**Key takeaway**: switching networking modes does not change inter-distro isolation. Both modes leave all WSL2 distros on the same Linux network namespace inside the utility VM. Only namespace-based isolation *inside* one distro (via `ip netns`, veth, bridge) provides the equivalent of `podman network create --internal`.

## Common pitfalls

- **Assuming mirrored mode adds isolation**. It changes the VM-to-host relationship, not the distro-to-distro relationship.
- **Believing NAT IP is stable**. Without mirrored mode, the WSL VM IP changes every boot. Tillandsias's current `--add-host alias:host-gateway` workaround sidesteps this.
- **Hyper-V firewall surprise**. With Windows 11 22H2+, inbound LAN connections are denied by default. Anything Tillandsias wanted to expose for LAN reachability needs an explicit `New-NetFirewallHyperVRule`.
- **DNS tunneling vs split-DNS proxies**. `dnsTunneling=true` (default) shortcuts DNS to the Windows resolver — useful, but it means a "DNS proxy" running inside WSL won't be authoritative from Windows. Disable if you need that.

## Sources of Truth

- `https://learn.microsoft.com/en-us/windows/wsl/networking` (fetched 2026-04-26)
- `https://learn.microsoft.com/en-us/windows/wsl/wsl-config` (fetched 2026-04-26) — `[wsl2]` and `[experimental]` sections.
- `cheatsheets/runtime/wsl/architecture-isolation.md` — why mode choice doesn't change inter-distro isolation.
- `cheatsheets/runtime/wsl/wslconfig-tunables.md` — full tunable list with defaults.
