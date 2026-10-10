# Microsoft MXC — what it is and what Tillandsias takes from it (2026-10-07)

Operator request 2026-10-07: investigate https://github.com/microsoft/mxc,
find learnings, and anything that could simplify Tillandsias' work. Two
read-only research agents (Fable) read the repository through `gh api`, its
docs and a `--depth 1` clone outside the checkout (nothing from it was run or
built). Paths below in `mxc:` are relative to that repository at its v1.0.0
tag; Tillandsias paths are on `linux-next` at 1e56609ed.

## 1. What MXC is

Microsoft eXecution Container: "a sandboxed code execution system for running
untrusted code (model output, plugins, and tools) on Windows, Linux, and
macOS" (`mxc:README.md`). It is an **in-process SDK** (Rust crate `mxc-sdk`,
NuGet `Microsoft.Mxc.Sdk`, npm `@microsoft/mxc-sdk`; MIT; Rust 1.93), not a
daemon or a product. The caller hands it one versioned JSON request
(`mxc:schemas/stable/mxc-config.schema.1.0.0.json`) naming a backend, a
filesystem policy (read-write / read-only / denied paths), a directional
network policy (`network.egress{default,allow,deny}` by CIDR/protocol/port, or
a caller-run loopback proxy) and a command. Lifecycle is one-shot
`run`/`spawn` or `provision → start → exec → stop → deprovision`
(`mxc:docs/container-lifecycle.md`).

Maturity: repo created 2026-02-06, ~485 commits, v1.0.0 "first stable
release" cut 2026-10-07 (the day of this note), several backends still marked
experimental. Very active.

Backends (`mxc:README.md`, `mxc:docs/backends/`):

| Host | Backends |
|---|---|
| Windows | `processcontainer` (AppContainer / PSEC tiers, WFP per-container egress; Windows 11 24H2+), `wslc` (OCI containers through the WSL Container SDK, WSL >= 2.9.9), `windows_sandbox`*, `isolation_session`*, `microvm`* (Nanvix), `hyperlight`* |
| Linux | `bubblewrap` (default; unprivileged userns, `--clearenv`, deny-by-default FS, slirp4netns + in-namespace firewall), `lxc` (root for networking), `microvm`*, `hyperlight`* |
| macOS | `seatbelt` only (kernel profile between fork and exec; network on/off + loopback, no host/CIDR filtering). No VM backend — Virtualization.framework and apple-containers are open requests (`mxc` issues #927, #958) |

`*` experimental. No Docker, Podman, containerd or devcontainer support. No
secrets store, no credential brokering, no multi-container network, no MCP.
The agent angle is explicit — it is a substrate for agent products running
"model output", not an agent itself.

## 2. Overlap with Tillandsias

MXC solves **one process, one declarative fs+network policy, three OSes**.
That is the forge-container boundary slice of Tillandsias
(`openspec/specs/forge-offline`, `crates/tillandsias-core/src/container_profile.rs`,
`crates/tillandsias-headless/src/exec_allowlist.rs`) plus the proxy-only egress
rule. It does not touch the enclave: the internal-only network with one
dual-homed Squid, the git mirror and its atomic relay, Vault and per-kind
AppRole policies, shared inference and its router, the Caddy service catalog,
the macOS VM substrate, the tray, or the multi-host ledger. MXC is a
primitive; Tillandsias is a system that could contain such a primitive. It is
not a competitor to the whole and does not make any of the enclave redundant.

## 3. Could it replace or simplify anything? Verdict: not now

- **Windows substrate through `wslc`.** The only tempting swap: OCI containers
  without our owned Fedora distro + Podman-in-guest. Blockers, from
  `mxc:docs/backends/wslc/`: networking is all-allow or all-deny bridged, with
  no internal networks, so the five-service enclave cannot be expressed; a
  proxy on the distro loopback is not reachable from a WSLC container; it
  needs a pre-release WSL (>= 2.9.9) and a closed-source `wslcsdk.dll`; it
  reintroduces a per-user daemon on a named pipe with serialized exec — the
  same readiness/handshake class as 795-jeym. Worth **measuring** (1553-gsp2),
  not adopting.
- **macOS.** Seatbelt is a process sandbox, not a VM; the forge needs Podman,
  hence a VM. Nothing to replace.
- **Linux.** Bubblewrap cannot replace Podman for the enclave. It, and Seatbelt
  on macOS, could cheaply sandbox host-side helpers the tray launches (host
  Chromium, agent attach) — a new boundary, tracked as research (1553-zyki).
- **Policy format.** MXC's schema is single-process. Adopting it without its
  engine buys nothing; borrowing its shape does (below).

## 4. Learnings Tillandsias takes

1. **One capability probe, not N refusals.** MXC exposes
   `available_backends()` / `platform_support()`: a backend is listed when it
   runs at all, and a missing optional capability is reported once, in
   `warnings[]` (`mxc:docs/development/plans/backend-support-probe-api.md`).
   Ours is the opposite shape: on a Mac without `setsid`, every preflight
   guard refuses on its own (1353-ryhq, 1375-amye), and the WSL preflight
   detects without saying what to do (756-dwkm). → **1553-hqrr**, and the
   OpenSpec change `substrate-capability-probe`.
2. **Ask the substrate, not the OS version.** MXC has no Windows-version
   floor; the gate is `WslcGetMissingComponents()`, asked at probe time and
   again at preflight. → folded into 1553-hqrr.
3. **Refuse a policy the backend cannot enforce, before starting anything.**
   "Unsupported policy must fail closed"; a validate/dry-run pass rejects it,
   and nothing ever falls back to the host network namespace. Our live
   instance: the launcher starts the proxy without the egress network the
   spec requires (1193-e6kv). → note on 1193-e6kv; OpenSpec change requirement
   "the enclave topology is validated before any container starts".
4. **Nested deadline budgets.** MXC holds a 540 s pull 60 s inside a 600 s
   daemon call so "a slow registry surfaces as a failed provision rather than
   a timeout that abandons a container". Our 900 s WSL readiness deadline is
   one flat number over bind + provision (798-vxj5, 795-jeym). → note on
   795-jeym and 798-vxj5.
5. **Denials are an authoring artifact.** MXC's Windows `--audit` mode
   captures every denial and turns it into a least-privilege policy draft
   (`mxc:docs/logging-access-denied.md`). Our operators grep the Squid log for
   `TCP_DENIED` to grow the allowlist. → **1553-jq6p**.
6. **Idle watchdog on the guest session.** MXC's daemons tear a session down
   after an idle timeout and give each container an opaque, backend-prefixed
   id. Our macOS guest ignores `requestStop` and every quit is a force-stop
   (1430-rnpd). → note on 1430-rnpd.
7. **Exact-version wire contracts.** Each MXC schema version has its own
   registered parser; retired fields are rejected, never migrated. Our
   control-wire and ledger already refuse unknown vocabulary; no new row,
   recorded as confirmation of an existing direction.

## 5. What Tillandsias has that MXC does not

The enclave as a unit (internal network, single dual-homed SSL-bumping Squid
with an ephemeral CA, git mirror with atomic upstream relay and an ssh-lane
sidecar holding the only key, Vault with per-container-kind policies, shared
inference with a policy router, service catalog), a macOS Linux-VM substrate,
the tray UX, credential isolation as a first-class rule, and the multi-host
plan/spec/litmus discipline.

## 6. Rows filed by this note

| Order | Role | What |
|---|---|---|
| 1553-hqrr | any | One substrate capability probe with warnings replaces per-guard refusals |
| 1553-jq6p | linux | `tillandsias proxy denials` lists denied destinations with counts |
| 1553-gsp2 | windows | Measured WSLC feasibility record on the Windows fleet host |
| 1553-zyki | any | Research: sandbox host-side helpers with bubblewrap / Seatbelt |

Notes appended to existing rows: 1193-e6kv (fail-closed topology validation),
795-jeym and 798-vxj5 (nested deadline budgets), 1430-rnpd (idle watchdog).
Orders 1553-2vx9 was minted and left unused.
