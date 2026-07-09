# Network Architecture Audit — Runtime Taxonomy & End-to-End Design

**Date:** 2026-07-09
**Classification:** audit+design
**Host:** any
**Observed by:** linux-big-pickle-20260709

## Observation

The networking stack has grown organically across multiple runtimes (HOST, GUEST,
CONTAINER, COMPILE/BUILD) without a unifying architectural document. Each runtime
has different requirements — enclave isolation, proxy egress, direct podman access,
host-network builds — but they share the same code paths and configuration surface.
This has led to:

1. **Missing vault image in `--init` builds** (order 244 was a symptom): vault image
   is built on-demand rather than as part of the declarative image set, and its build
   happens in the user-runtime path rather than the init/build-runtime path.

2. **HTTP 401 from `gh auth login` inside git-login container** (2026-07-09): the
   proxy-routed auth request to `api.github.com` fails with Bad Credentials. Root
   cause may be proxy header injection, allowlist gap, DNS resolution order, or
   TLS interception (CA bundle missing/expired in container).

3. **Vault rebuilds on repeated login attempts**: the vault container/image is
   sometimes rebuilt when re-running `--github-login`, indicating the init/build
   caching boundary is unclear between user-runtime and build-runtime.

4. **No declared network scenarios**: the codebase has no explicit taxonomy of
   which network topology applies to which runtime mode.

## Impact

`--github-login` is unreliable on the primary Linux development host. Debugging is
slow because the network topology is implicit — every debug run requires tracing
through podman networks, proxy config, vault secrets, and the container dependency
graph without a reference architecture.

## Required Agents

At least 3 agents must verify this packet as complete:
- `opencode-bigpickle`
- `antigravity-gemini`
- `codex-gpt55-highthink`

## Deliverable

A ratified network architecture document covering:

1. **Runtime Taxonomy Table**: HOST, GUEST (WSL2/macOS-VZ/Toolbox),
   CONTAINER (forge/proxy/vault/inference/git/router), COMPILE/BUILD — each
   with its network topology, egress rules, DNS config, proxy awareness, and
   podman capabilities.

2. **Network Scenarios Catalog**: For each runtime, the set of valid network
   topologies (enclave-internal, enclave+egress, host-network, none) and which
   scenario applies to which operation (init, login, forge, cloud project,
   diagnostics).

3. **Dependency Graph Awareness**: How `container_deps.rs` must account for
   runtime context — e.g., BUILD runtime should not require vault; GUEST runtime
   needs different proxy paths.

4. **Platform Abstraction Layer**: For each HOST platform (Linux bare, WSL2,
   macOS VZ, Silverblue Toolbox), the network bridge/forwarding mechanism used
   and how it maps to the runtime topology.

5. **Spec/Cheatsheet Patch List**: Specific files in `openspec/specs/` and
   `docs/cheatsheets/` that need updating to reflect the ratified architecture.

---

# DRAFT v1 — Network Architecture (research phase, 2026-07-09)

**Author:** linux-macuahuitl-fable5-20260709T1923Z (lease
network-architecture-audit-linux-20260709T1946Z)
**Ratification:** PENDING — awaiting verified-by events from opencode-bigpickle,
antigravity-gemini, codex-gpt55-highthink per the packet's completion gate.
Everything below is source-verified against linux-next @ 133538ef; every claim
carries a file reference so verifiers can falsify it.

## 1. Runtime Taxonomy Table (NA-01)

There are exactly four runtime kinds. A process can tell which one it is in:
`TILLANDSIAS_HOST_KIND=forge` marks CONTAINER(forge); `/run/WSL` marks
GUEST(WSL2); `/run/ostree-booted` marks HOST(immutable); otherwise HOST.

| Runtime | Where | Network topology | Egress | DNS | Proxy awareness | Podman |
|---|---|---|---|---|---|---|
| HOST (Linux bare, mutable) | dev workstation | host netns | direct | systemd-resolved (+ enclave drop-in mapping `vault` → enclave gateway, root only: `main.rs` `ensure_enclave_host_dns`, `ENCLAVE_RESOLVED_CONF`) | none (host tools go direct) | full rootless podman; owns all networks/containers below |
| HOST (Silverblue, immutable) | operator laptop | host netns | direct | systemd-resolved | none | host podman for runtime; compile happens in the toolbox builder (order 239, `scripts/with-tillandsias-builder.sh`) |
| GUEST (WSL2 Fedora / macOS VZ Fedora) | VM owned by the tray | VM NAT netns; control plane over vsock (VZ `guest_cid`, `vm-layer/src/vz.rs`) / hvsock (`transport_windows.rs`, `wsl.rs`) | via VM NAT | WSL: mirrored resolv.conf handling in `ensure_enclave_host_dns`; VZ: VM DHCP | none at guest level; in-guest containers use the same enclave model below | tillandsias-headless runs INSIDE the guest and owns a full in-guest podman substrate (same enclave/egress model, one level down) |
| CONTAINER (enclave services + forge) | podman on HOST or GUEST | see §1.1 matrix | only via squid or dual-home | aardvark-dns resolves network aliases (`vault`, `proxy`, `tillandsias-git`, `inference`, `router`) | forge + login get the canonical 6 proxy env vars + `NODE_USE_ENV_PROXY=1` (`main.rs` `proxy_env_args`/`apply_proxy_env`) | none — containers must NOT reach the podman socket (exception under design: order 137 vsock→podman-exec authn) |
| COMPILE/BUILD | `podman build` + cargo | podman default build network (pasta/slirp NAT) — NOT the enclave | direct NAT with `--dns 8.8.8.8` hardcoded (`main.rs` `ensure_image_exists`) | forced Google DNS | NONE — builds bypass squid entirely; squid's PERMISSIVE :3129 ("image builds") has zero callers (`grep -rn 3129` → only `images/proxy/`) | n/a (is podman) |

### 1.1 CONTAINER network matrix (source-verified)

| Container | Networks | Alias | Effective egress path | Source |
|---|---|---|---|---|
| tillandsias-proxy (squid 6, dual-port SSL-bump) | enclave + egress | `proxy` | direct NAT (egress leg) | `main.rs` `build_proxy_run_args` (`ENCLAVE_EGRESS_NETS`) |
| tillandsias-git-\<project\> (mirror) | enclave + egress | `tillandsias-git` | proxy env applied (`main.rs:2262`) so HTTPS forwards tunnel through squid; egress leg is the NAT fallback for env-ignoring tools; post-receive forwards to GitHub with a vault-fetched token | `main.rs` `build_git_run_args`, `images/git/` |
| tillandsias-vault | enclave only | `vault` | none; peers reach it via `https://vault:8200` and NO_PROXY exempts it | `vault_bootstrap.rs` launch args; `ENCLAVE_NO_PROXY_BASE` |
| tillandsias-inference (ollama) | enclave only | `inference` | squid :3128 via proxy env (`.ollama.ai` is a bump domain) | `main.rs` `build_inference_run_args` |
| tillandsias-router (reverse proxy) | enclave only + publish `127.0.0.1:<port>→8080` | `router` | none outbound; inbound from host browser via loopback publish | `main.rs` `build_router_run_args` |
| forge-\<project\> (+ per-agent modes) | enclave only | `forge-<project>` | squid :3128 via proxy env only | `main.rs` `build_forge_agent_run_args` |
| observatorium web | enclave only | — | none (read-only static server) | `main.rs` `build_observatorium_web_args` |
| project browser (chromium) | **host network** (+SYS_CHROOT) | — | direct host egress; trusts tillandsias CA; reaches router at `127.0.0.1:<port>` | `main.rs` `build_project_browser_spec` |
| github-login helper (ephemeral) | enclave + egress | — | proxy env applied AND dual-homed (env wins for gh; dual-home covers env-ignoring tools) | `main.rs` `run_provider_login` + regression test `github_login_helper_dual_homes_onto_managed_egress_network` |

Networks: `tillandsias-enclave` = `--internal` bridge, default subnet
`10.0.42.0/24` (`TILLANDSIAS_ENCLAVE_SUBNET` overrides); `tillandsias-egress` =
managed NAT bridge (exists because podman's rootless default net is absent
after `podman system reset`). `ensure_enclave_network` always ensures egress
first (`main.rs:1629`).

Squid: `:3128` STRICT (allowlist `images/proxy/allowlist.txt`, 146 domains) —
`no_bump` CONNECT-passthrough for auth-sensitive domains (github, anthropic,
openai, google, microsoft…), SSL-bump + cache for package registries; `:3129`
PERMISSIVE (all domains) — currently orphaned (see Patch P6).

## 2. Network Scenarios Catalog (NA-02)

Six canonical scenarios; every operation must name one per container it runs.

- **S0 none** — no network. (Nothing uses this today; candidate for
  observatorium.)
- **S1 enclave-internal** — enclave only, no proxy env: vault, router,
  observatorium.
- **S2 enclave+proxy-egress** — enclave only + proxy env vars: forge,
  inference. All egress through squid :3128 allowlist.
- **S3 dual-homed** — enclave + egress legs: proxy, git-service,
  github-login helper. Reserved for infrastructure that must speak to the
  internet with credentials that must not transit the bump CA.
- **S4 host-network** — chromium browser only (display + loopback router).
- **S5 build-default** — podman build netns, `--dns 8.8.8.8`: every
  `ensure_image_exists` call.

| Operation | Containers touched | Scenarios |
|---|---|---|
| `--init` | builds 9 images (proxy git inference router chromium-core chromium-framework forge-base forge web — `run_init`, `main.rs:3742`); creates networks; **does NOT build vault** | S5 + network creation |
| `--github-login` / provider login | vault (S1, built+launched on demand at `vault_bootstrap.rs:1071` — the §Observation-1 gap), proxy (S3), login helper (S3) | S1+S3 |
| forge launch (tray or CLI) | proxy, git, inference, forge + image ensure of 4 (`ensure_enclave_for_project`, `main.rs:7350`) | S2+S3+S5 |
| cloud project list | vault, proxy, gh in helper | S1+S3 |
| status check / diagnostics | ensures 6 images (`run_status_check`, `main.rs:4492`) — heavyweight for a read path | S5 (should be S0/read-only) |
| opencode / web | proxy git inference forge (+router web chromium for web mode) | S2+S3+S4+S5 |

## 3. Dependency Graph Awareness (NA-03)

`container_deps.rs` today models one context: the GitLogin bring-up
(EnclaveNetwork → EgressNetwork/CaBundle → Vault → Proxy → GitLogin). The
taxonomy demands a **RuntimeContext** dimension:

1. `Ctx::Build` — needs NOTHING from the graph (no vault, no proxy). Image
   ensure must stop being an implicit side effect of user operations
   (status-check building 6 images) and become an explicit Build-context node
   set.
2. `Ctx::HostRuntime` — full graph as today; liveness probe (order 228) may
   re-ensure only nodes tagged steady-state (Vault, Proxy) — and must do so
   under the order 232-235 concurrency safeguards.
3. `Ctx::GuestRuntime` — same graph, but host-DNS nodes
   (`ensure_enclave_host_dns`) are no-ops or WSL-specific.
4. `Ctx::Forge` (in-container) — graph is READ-ONLY: a forge must never
   ensure/launch host containers; it consumes `vault`/`proxy`/`tillandsias-git`
   aliases that already exist. (Today's guard is the satisfier erroring on
   GitLogin only; order 252 extends coverage to forge launch paths.)
5. Vault must join the declarative image set for Build context so `--init`
   pre-builds it (closes §Observation-1/3: on-demand vault build+rebuild during
   login).

## 4. Platform Abstraction Layer (NA-04)

| HOST platform | VM/bridge mechanism | Control plane | Podman location |
|---|---|---|---|
| Linux bare (mutable) | none | unix socket (host-local control wire) | host rootless podman |
| Fedora Silverblue (immutable) | toolbox container for COMPILE only (order 239) | unix socket | host rootless podman (runtime); toolbox shares it for builds |
| Windows | WSL2 Fedora guest | hvsock (`vm-layer/src/transport_windows.rs`, `wsl.rs`); tray on host, headless in guest | in-guest podman |
| macOS | Virtualization.framework Fedora guest (`vz.rs`, stable `guest_cid`) | virtio-vsock (`transport_macos.rs`); `~/src` mounted via virtiofs (order 193) | in-guest podman |

Uniformity claim (to ratify): the CONTAINER layer (§1.1) is byte-identical
across all four platforms because tillandsias-headless always runs adjacent to
the podman it manages (host on Linux, in-guest on WSL2/VZ). Platform
differences are confined to (a) the host↔headless transport, and (b) host-DNS
integration. The secure channel work (orders 141/142/145/184/194,
`tillandsias-secure-channel`) hardens transport (a); the vsock→podman-exec
authn gap is order 137.

## 5. Spec/Cheatsheet Patch List (NA-05)

- **P1 `openspec/specs/enclave-network/spec.md`** — Purpose says "Only the
  proxy container has external access (dual-homed)". FALSE since git-mirror
  upstream forwarding (order 167) and the login-helper dual-home: git-service
  and the login helper are also dual-homed (`main.rs:2242`,
  `run_provider_login`). Patch: enumerate S3 members + cite this taxonomy.
- **P2 `openspec/specs/enclave-network/spec.md`** — "cleanup on app exit
  removes the network" scenario: verify against current long-running headless
  behavior; likely obsolete → tombstone or re-scope to `--reset` flows.
- **P3 `openspec/specs/proxy-container/spec.md` +
  `cheatsheets/runtime/enclave-proxy-patterns.md`** — add the S2/S3 split and
  the `NODE_USE_ENV_PROXY` contract; document `ENCLAVE_NO_PROXY_BASE` as the
  single NO_PROXY source of truth.
- **P4 `openspec/specs/host-guest-transport/spec.md` + `vsock-transport`** —
  add the §4 platform matrix (hvsock vs virtio-vsock vs unix socket) as
  normative.
- **P5 new spec `openspec/specs/network-scenarios/spec.md`** — S0-S5 catalog
  (§2) with the operation table as scenarios; litmus: a source audit that every
  `--network` / `.network(` site names a scenario constant, so new containers
  must declare a scenario to compile/pass.
- **P6 `images/proxy/squid.conf` + spec** — decide :3129's fate: either wire
  image builds through it (replacing `--dns 8.8.8.8` bypass) or delete the
  port. Recommendation: wire builds through it on HOST runtime where the
  proxy exists; keep direct as bootstrap fallback (proxy image itself,
  chicken-and-egg: `plan/issues/podman-proxy-reset-chicken-and-egg-2026-07-08.md`).
- **P7 `openspec/specs/headless-mode/spec.md`** — document per-operation image
  ensure lists (or their unification per §3.1) and the vault-in-init change.

## 6. Root-cause notes for the three §Observation failures (NA-06)

1. **Vault missing from `--init`** — CONFIRMED at source: `run_init` image
   list (`main.rs:3742`) lacks vault; it is built on demand at
   `vault_bootstrap.rs:1071` inside the login path. Fix direction: §3 item 5.
2. **HTTP 401 from `gh auth login`** — network exonerated by this audit: the
   helper reaches api.github.com through squid's `no_bump` CONNECT tunnel
   (token cannot be mangled by the bump CA) or, for env-ignoring tools, the
   dual-homed egress leg. 401 "Bad Credentials" therefore means GitHub rejected
   the presented token → stale/expired vault secret, token whitespace, or scope
   loss. Belongs to order 246 (credential & secrets audit); smallest
   diagnostic: `podman exec tillandsias-vault vault kv get …github-token`,
   compare with a curl using the same token via the same tunnel.
3. **Vault rebuilds on repeated login** — consistent with (1): the login path
   owns vault image ensure; any content-identity/cache miss (see
   `check_cache_integrity`, `spec:forge-staleness` analogues for vault) forces
   a rebuild inside a user flow. Moving vault to the init/Build context makes
   login a pure S1/S3 runtime operation and the rebuild disappears from the
   login path by construction.

## 7. Follow-up packets proposed

- Wire vault into the `--init` declarative image set (§3.5, §6.1) — small,
  high-value, closes two of three observed failures structurally.
- RuntimeContext enum in container_deps (§3) — pairs with order 252.
- P5 network-scenarios spec + `--network`-site litmus.
- P6 build-egress decision (squid :3129 vs `--dns 8.8.8.8`).

