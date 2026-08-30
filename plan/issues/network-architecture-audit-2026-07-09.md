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
   was built on-demand rather than as part of the declarative image set, and its build
   happened in the user-runtime path rather than the init/build-runtime path.
   RESOLVED (order 253, commit 8b6c7031, 2026-07-09): `run_init` now builds vault
   third in its 10-image declarative set (`main.rs:5884-5895`, rationale comment
   `main.rs:5879-5883`); the login-path build survives only as a fail-soft
   fallback for runtimes that skipped `--init` (`vault_bootstrap.rs:1410-1426`).

2. **HTTP 401 from `gh auth login` inside git-login container** (2026-07-09): the
   proxy-routed auth request to `api.github.com` failed with Bad Credentials; root
   cause was suspected to be proxy header injection, allowlist gap, DNS resolution
   order, or TLS interception. RESOLVED — the cause was none of the four network
   hypotheses: gh's interactive masked prompt put the container pty into raw
   char-at-a-time mode, so a token pasted over `podman exec -it` picked up
   bracketed-paste escape bytes (`ESC[200~ … ESC[201~`) or was truncated; gh
   validated garbage and GitHub returned 401 (`main.rs:7193-7205`). The login now
   reads the token via a cooked-mode shell `read -rs` piped to
   `gh auth login --with-token` (`main.rs:7206-7215`), plus a non-interactive
   `--with-token` stdin lane (`main.rs:7223-7230`; mode selection
   `main.rs:7416-7430`); the interactive gh prompt is deliberately avoided.

3. **Vault rebuilds on repeated login attempts**: the vault container/image was
   sometimes rebuilt when re-running `--github-login`, indicating the init/build
   caching boundary was unclear between user-runtime and build-runtime.
   RESOLVED by the same order-253 change: `build_vault_image` checks
   `image_exists_sync` on the init-built identity tag and returns early
   (`vault_bootstrap.rs:1410-1423`), so repeated logins are zero-build on an
   initialized runtime; the init/build context owns the vault build, and the
   login path only falls back to building when `--init` was never run.

4. **No declared network scenarios**: the codebase has no explicit taxonomy of
   which network topology applies to which runtime mode.

## Impact

`--github-login` was unreliable on the primary Linux development host (since
resolved — see Observation 2). Debugging remains slow because the network
topology is implicit — every debug run requires tracing
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
**Revision 2 (provenance):** the draft was originally stamped against linux-next
@ 133538ef; that baseline fell ~1,383 commits behind and several audited
subsystems changed materially. A 2026-08-11 fact-check pass (7-agent sweep)
re-verified every claim and applied 23 corrections inline. Everything below is
now revised 2026-08-11 against osx-next @ HEAD (65b2b900-era; post-0a972411
mirror enclave-only, post-63784ddb browser hardening, post-order-253
vault-in-init); every claim carries a file reference so verifiers can falsify it.
**Ratification:** PENDING — awaiting verified-by events from opencode-bigpickle,
antigravity-gemini, codex-gpt55-highthink per the packet's completion gate.
Re-verification by those three agents against the new baseline is still
required; the Revision-2 pass corrects stale claims but does not substitute for
the gate.

## 1. Runtime Taxonomy Table (NA-01)

There are exactly four runtime kinds. A process can tell which one it is in:
`TILLANDSIAS_HOST_KIND=forge` marks CONTAINER(forge); `/run/WSL` marks
GUEST(WSL2); `/run/ostree-booted` marks HOST(immutable); otherwise HOST.
(The `RuntimeLane` taxonomy — desktop-user-session / headless-service-account /
dev-test, `crates/tillandsias-podman/src/lib.rs` `RuntimeLane` / `current_runtime_lane` — is an orthogonal
Linux session-ownership axis that pre-dates this draft, not a fifth kind.
Known gap, true at draft time too: the recipe has no marker for the macOS VZ
guest, which classifies as HOST.)

| Runtime | Where | Network topology | Egress | DNS | Proxy awareness | Podman |
|---|---|---|---|---|---|---|
| HOST (Linux bare, mutable) | dev workstation | host netns | direct | systemd-resolved (+ enclave drop-in mapping `vault` → enclave gateway, root only: `main.rs` `ensure_enclave_host_dns`, `ENCLAVE_RESOLVED_CONF`) | none (host tools go direct) | full rootless podman; owns all networks/containers below |
| HOST (Silverblue, immutable) | operator laptop | host netns | direct | systemd-resolved | none | host podman for runtime; compile happens in the toolbox builder (order 239, `scripts/with-tillandsias-builder.sh`) |
| GUEST (WSL2 Fedora / macOS VZ Fedora) | VM owned by the tray | VM NAT netns; control plane over vsock (VZ `guest_cid`, `vm-layer/src/vz.rs`) / hvsock (`transport_windows.rs`, `wsl.rs`) | via VM NAT | WSL: mirrored resolv.conf handling in `ensure_enclave_host_dns`; VZ: VM DHCP | none at guest level; in-guest containers use the same enclave model below | tillandsias-headless runs INSIDE the guest and owns a full in-guest podman substrate (same enclave/egress model, one level down) |
| CONTAINER (enclave services + forge) | podman on HOST or GUEST | see §1.1 matrix | only via squid or dual-home | aardvark-dns resolves network aliases (`vault`, `inference`, `router`; `proxy` via container hostname — `--hostname proxy`, no explicit alias, `main.rs` `build_proxy_run_args`; the shared `tillandsias-git` alias was RETIRED by order 659-8faj, commit bb334952 — two projects gave one name two A records with non-deterministic routing — replaced by per-project `git-<project>` from `main.rs` `git_mirror_service_identity`, delivered to clients via `TILLANDSIAS_GIT_SERVICE`) | forge + login get the canonical 6 proxy env vars + `NODE_USE_ENV_PROXY=1` (`main.rs` `proxy_env_args`/`apply_proxy_env`) | none — containers must NOT reach the podman socket (the authn exception is no longer order 137, which was superseded: the operator chose the full encrypted, version-bound control channel — designed order 140, implemented order 141; slices 1-3 landed, 4 and 6 remain, and a 2026-07-28 adversarial check refuted "already satisfied" — secure control wire is default-off; orders 137 / 140 / 141 in the ledger — cited by ORDER, never by `plan/index.yaml` line, because compaction rewrites that file's line numbers by design) |
| COMPILE/BUILD | `podman build` + cargo | podman default build network (pasta/slirp NAT) — NOT the enclave | direct NAT with `--dns 8.8.8.8` hardcoded (`main.rs` `ensure_image_exists`) | forced Google DNS | NONE for podman image builds — every Rust build path forces `--http-proxy=false` (`client.rs:708-721`). But "builds bypass squid entirely" is over-broad: host-side cargo egress in the dev flow routes through a dev-cache squid (stock `docker.io/library/squid:6.1`, not the tillandsias-proxy image) published on `127.0.0.1:3129` when active (`build.sh:355-411`; `openspec/specs/dev-build/spec.md:165-183`). The narrower claim survives: the tillandsias-proxy container's own PERMISSIVE :3129 has zero runtime callers — no hits in `crates/` or `scripts/`, spec marks it "Reserved for future use" (`openspec/specs/proxy-container/spec.md:101`) | n/a (is podman) |

### 1.1 CONTAINER network matrix (source-verified)

| Container | Networks | Alias | Effective egress path | Source |
|---|---|---|---|---|
| tillandsias-proxy (squid 6, dual-port SSL-bump) | enclave + egress | `proxy` | direct NAT (egress leg) | `main.rs` `build_proxy_run_args` (`ENCLAVE_EGRESS_NETS`) |
| tillandsias-git-\<project\> (mirror) | **enclave ONLY** (`ENCLAVE_ONLY_NET`, `main.rs` `build_git_run_args` — order 606-9wqd, commit 0a972411 removed the egress leg: it granted unscoped internet, see `plan/issues/git-mirror-egress-spec-divergence-audit-2026-08-10.md`) | `git-<project>` (per-project, `main.rs` `git_mirror_service_identity`; the shared `tillandsias-git` alias is retired — "do not reintroduce a shared alias", order 659-8faj, the "do not reintroduce a shared alias" comment in `main.rs` `build_git_run_args`) | proxy env applied (`main.rs` `build_git_run_args` via `proxy_env_args`) so HTTPS forwards tunnel through squid; NO NAT fallback remains; the must-succeed upstream relay to GitHub runs in PRE-receive (`tillandsias-relay-refs`, `images/git/pre-receive-hook.sh:480`, `relay-refs.sh:161-173`) with the token vault-fetched at push time via a git credential helper, never in argv (`images/git/git-credential-tillandsias.sh:47`); post-receive is bookkeeping only (`images/git/post-receive-hook.sh:5-8`) | `main.rs` `build_git_run_args`, `images/git/` |
| tillandsias-vault | enclave only | `vault` | none; peers reach it via `https://vault:8200` and NO_PROXY exempts it | `vault_bootstrap.rs` launch args; `ENCLAVE_NO_PROXY_BASE` |
| tillandsias-inference (ollama) | enclave only | `inference` | squid :3128 via proxy env (`.ollama.ai`/`.ollama.com` are plain allowlist entries, spliced end-to-end — squid now bumps ONLY `release-assets.githubusercontent.com`; `images/proxy/allowlist.txt:134-135`, `squid.conf:64-80`) | `main.rs` `build_inference_run_args` |
| tillandsias-router (reverse proxy) | enclave only + publish `127.0.0.1:<port>→8080` | `router` | none outbound; inbound from host browser via loopback publish | `main.rs` `build_router_run_args` |
| forge-\<project\> (+ per-agent modes) | enclave only | `forge-<project>` | squid :3128 via proxy env only | `main.rs` `build_forge_agent_run_args` |
| observatorium web | enclave only | — | none (read-only static server) | `main.rs` `build_observatorium_web_args` |
| project browser (chromium) | podman default rootless netns (pasta) — hardened 2026-08-08, commit 63784ddb, order 615-x3b8: no `.network("host")`, no `SYS_CHROOT`; read-only rootfs, `--cap-drop=ALL` with no `--cap-add` at all, no-new-privileges, `--userns=keep-id`, tmpfs HOME/config/cache | — | egress via default rootless NAT; trusts tillandsias CA (`intermediate.crt` bind-mount, `SSL_CERT_FILE`/`TILLANDSIAS_CA_BUNDLE`); reaches router via `http://<service>.<project>.localhost:<host_port>` against the router's `127.0.0.1:<host_port>:8080` publish (`main.rs` `build_project_browser_spec`, router-publish URL construction) | `main.rs` `build_project_browser_spec`; regression test asserts absence of `--cap-add`/`SYS_CHROOT`/`host` (the `SYS_CHROOT` / `--cap-add` / `host` absence assertions in `main.rs`'s browser-spec tests) |
| github-login helper (ephemeral) | enclave + egress | — | proxy env applied AND dual-homed (env wins for gh; dual-home covers env-ignoring tools) | `main.rs` `run_provider_login` + regression test `github_login_helper_dual_homes_onto_managed_egress_network` |

Networks: `tillandsias-enclave` = `--internal` bridge, default subnet
`10.0.42.0/24` (`TILLANDSIAS_ENCLAVE_SUBNET` overrides); `tillandsias-egress` =
managed NAT bridge (exists because podman's rootless default net is absent
after `podman system reset`). `ensure_enclave_network` always ensures egress
first (`main.rs` `ensure_enclave_network`, egress branch). Runtime reproduction on two independent hosts
(2026-08-10 egress-divergence audit) confirmed the enclave's `internal: true`
is airtight ("reaches nothing") while the egress leg granted arbitrary
unscoped outbound (reached example.com/pypi.org) — measured before the mirror's
egress leg was removed
(`plan/issues/git-mirror-egress-spec-divergence-audit-2026-08-10.md:131,215,240`).

Squid: `:3128` STRICT (allowlist `images/proxy/allowlist.txt`, 112 domain
entries) — allowlist-only with `http_access deny all` plus `deny_info
TCP_RESET` on denied runtime traffic (`squid.conf:92-109`). The bump
architecture INVERTED post-draft: there is no `no_bump` ACL and no
registry-bump list — squid peeks at SslBump step 1, bumps ONLY
`release-assets.githubusercontent.com` (so the ~1.44GB Ollama GitHub release
assets can be cached, `squid.conf:133-135`), and splices ALL other traffic;
package registries and every auth-sensitive destination remain end-to-end
spliced (`squid.conf:64-80`); `:3129` PERMISSIVE (all domains) — still
orphaned inside the proxy image (see Patch P6).

## 2. Network Scenarios Catalog (NA-02)

Six canonical scenarios; every operation must name one per container it runs.

- **S0 none** — no network. (Nothing uses this today; candidate for
  observatorium.)
- **S1 enclave-internal** — enclave only, no proxy env: vault, router,
  observatorium.
- **S2 enclave+proxy-egress** — enclave only + proxy env vars: forge,
  inference — and, since commit 0a972411 (2026-08-10, orders
  606-9wqd/654-7ur4), the git mirror, the remote-projects gh helper, and the
  GitHub clone helper, all now enclave-only with proxy env at squid :3128
  after their egress legs were removed (`main.rs:3031-3037,3049`;
  `remote_projects.rs:316-328,655-657,679-693`). All egress through squid
  :3128 allowlist.
- **S3 dual-homed** — enclave + egress legs: proxy (the ONLY spec-sanctioned
  taker, `main.rs:2556`) + github-login helper (`main.rs:7589,7625`) — and the
  helper's dual-home was itself ruled an unsanctioned spec violation pending a
  verdict ("One sanctioned dual-homing, five unsanctioned runtime sites",
  `plan/issues/git-mirror-egress-spec-divergence-audit-2026-08-10.md`).
  git-service left this set on 2026-08-10 (commit 0a972411 dropped the
  mirror's egress leg). The original rationale — "credentials must not transit
  the bump CA" — is obsolete: squid now splices everything except GitHub
  release assets (`squid.conf:77-79`), so credentials do not transit the bump
  CA even when proxied, and the runtime reproduction showed the egress leg
  grants unscoped internet access.
- **S4 host-network** — RETIRED, used by NOTHING: commit 63784ddb (2026-08-08,
  order 615-x3b8) moved the chromium browser off host network onto podman's
  default rootless netns, and the policy layer now denylists `--network=host`
  as a disallowed passthrough option
  (`crates/tillandsias-podman/src/policy.rs:271,280`).
- **S5 build-default** — podman build netns, `--dns 8.8.8.8`: every
  `ensure_image_exists` call.

| Operation | Containers touched | Scenarios |
|---|---|---|
| `--init` | builds 10 images INCLUDING vault (proxy git **vault** inference router chromium-core chromium-framework forge-base forge web — `run_init`, `main.rs:5847`, array + order-253 rationale comment at `main.rs:5879-5895`, commit 8b6c7031); does NOT create the enclave/egress networks — no ensure_enclave_network/ensure_egress_network call in the run_init body; networks are created by the launch/status/login lanes (`main.rs:6948,8882,9405,10531`) and the container_deps satisfier (`container_deps.rs:303-304`) | S5 |
| `--github-login` / provider login (now `run_provider_login`, generalized to multiple providers, `main.rs:7468`) | vault (S1, normally PRE-BUILT by `--init` per order 253; `build_vault_image` survives only as fail-soft fallback, `vault_bootstrap.rs:598,1397`), proxy (S3), login helper (S3 — dual-home flagged unsanctioned, see S3); bring-up routes through `container_deps::ensure_git_login` — topological Vault+Proxy ensure replacing the ad-hoc chain (`main.rs:7515-7522`, order 227); token entry is a cooked-mode shell read piped to `gh auth login --with-token` (`main.rs:7201-7214`) | S1+S3 |
| forge launch (tray or CLI) | SIX managed containers — vault, proxy, router, git, inference, forge; image ensure of 4 = `["router","git","inference","forge"]` (`main.rs:11081`; proxy's image is verified inside the dependency-model satisfier instead) via `ensure_enclave_for_project` (`main.rs:11028`), routing through `container_deps::ensure_forge_launch` (`main.rs:11067`); Vault is a structural ForgeLaunch prerequisite (`container_deps.rs:84-98`, windows-260716-2) and router is brought up before the per-project stack so squid's `cache_peer` resolves (`main.rs:11110-11128`) | S1+S2+S3+S5 |
| cloud project list | vault lease (S1), proxy self-heal (S3), containerized gh helper — no longer dual-homed: enclave-only + explicit proxy:3128 env since 0a972411, S2 posture (`remote_projects.rs:295-306,316-328,400-401,436-437`) | S1+S2+S3 |
| status check / diagnostics | ensures EIGHT images — proxy git inference chromium-core chromium-framework forge router web (`run_status_check`, `main.rs:6934`, array at `main.rs:6950-6961`; router+web added 2026-07-16 for the version-handover phantom-pull gap) — and launches status-proxy, a throwaway per-project git mirror with vault identity provisioning + credential mint, status-inference, and a one-shot status forge (`main.rs:6985-7075`); heavyweight for a read path, and heavier than at draft time | S5 (should be S0/read-only) |
| opencode / web | CLI opencode: proxy router git inference forge — 5-image ensure (`main.rs:9403-9413`); router is no longer web-mode-only (preflighted in the CLI lane since the 2026-07-15 macOS cold-forge fix). Web mode (`run_opencode_web_mode`, `main.rs:10490`): 7-image ensure WITHOUT `web` (`main.rs:10533-10541`) + chromium browser on the default rootless netns; the `web` image belongs to `run_observatorium_mode` (`main.rs:8884`) and `publish_local_service` (`main.rs:13379-13424`) | S2+S3+S5 (no S4 — the browser runs on a default-netns posture the catalog has no name for) |

## 3. Dependency Graph Awareness (NA-03)

> REVISED 2026-08-30 (lenovinha, linux slice). Every claim below was
> re-verified against the tree before its citation was touched, and the
> citations are now anchored on SYMBOL NAMES for the reason recorded in §L1.
> The file is `crates/tillandsias-headless/src/container_deps.rs` — **not**
> `tillandsias-podman`, which the previous text left implicit while naming the
> podman crate in the same paragraph. See §L2 for what drifted.

`container_deps.rs` today models TWO launch targets plus a derived wrapper: the
GitLogin bring-up (EnclaveNetwork → EgressNetwork/CaBundle → Vault → Proxy →
GitLogin — unchanged) and `Service::ForgeLaunch` (`container_deps.rs` `enum
Service`), whose `DEPS` entry now carries **SIX** edges, not the five this
draft was written against:

| edge | why |
|---|---|
| `EnclaveNetwork` | original |
| `EgressNetwork` | original |
| `CaBundle` | original |
| `Proxy` | original |
| `Vault` | windows-260716-2: the git-mirror relay credential made mint-or-fail-loud a hard launch requirement |
| `NixCache` | **ORDER 801-vm4p, new since the draft** |

`Service::NixCache` is a launch-graph node this document did not have. It rides
the forge-launch graph so a cache is ensured wherever a forge comes up, and its
ensure SKIPS with `Ok` on a host with no nix and no store — so the edge adds no
new launch REQUIREMENT anywhere, which is why it could land without breaking a
lane. Its own edges are `EnclaveNetwork` and `CaBundle` only. For a section
whose subject IS the dependency graph, an unlisted node is a content gap rather
than citation rot, and it is the substantive NA-03 finding of this pass.

`ensure_forge_launch()` (`container_deps.rs` `pub fn ensure_forge_launch`)
returns the typed witness `Up<ForgeLaunchReady>` and is the shared wrapper both
tray launch (`ensure_enclave_for_project`) and CLI launch
(`run_forge_agent_cli_mode`) route through; `ensure_service_catalog` /
`CatalogServiceReady` layers on top.

**The SHAPE of that convergence changed and the old text implied otherwise.**
There is now exactly ONE production call site — inside
`main.rs` `pub(crate) fn ensure_enclave_for_project` — and the CLI reaches it
TRANSITIVELY: `run_forge_agent_cli_mode` calls `ensure_enclave_for_project`,
which calls `ensure_forge_launch`. The previous text cited two locations, which
reads as two parallel call sites. The order-252 property (both routes are
covered) still holds; it is now enforced by convergence rather than by
duplication, which is stronger and worth stating as such. Pinned by
`main.rs` `fn enclave_bringup_cleans_up_before_ensuring_prerequisites`, a
source-scanning test that also fixes the ORDER (cleanup must precede the
ensure, or the ensure's proxy is torn down — order 298).

The taxonomy still demands a **RuntimeContext** dimension:

1. `Ctx::Build` — needs NOTHING from the graph (no vault, no proxy). Image
   ensure remains an implicit side effect of user operations
   (`main.rs` `fn ensure_versioned_images`, called from four separate paths)
   and must become an explicit Build-context node set — no such node set exists
   yet. The RuntimeLane taxonomy that did land classifies host session lanes,
   not build vs runtime contexts
   (`crates/tillandsias-podman/src/lib.rs` `pub enum RuntimeLane` /
   `pub fn current_runtime_lane`). (One boundary did move: the forge-launch
   path's `ensure_versioned_images` no longer includes `proxy` — that is folded
   into the order-252 satisfier, which reaches it through
   `main.rs` `fn ensure_proxy_running`, the one remaining caller that passes
   `&["proxy"]`. Order 252, not a line in the ledger.)
2. `Ctx::HostRuntime` — full graph as today; liveness probe (order 228) may
   re-ensure only nodes tagged steady-state (Vault, Proxy) — and must do so
   under the order 232-235 concurrency safeguards.
3. `Ctx::GuestRuntime` — same graph, but host-DNS nodes
   (`ensure_enclave_host_dns`) are no-ops or WSL-specific.
4. `Ctx::Forge` (in-container) — graph is READ-ONLY: a forge must never
   ensure/launch host containers; it consumes the `vault`/`proxy`/`git-<project>`
   aliases that already exist. Order 252 COMPLETED (2026-07-09T20:07:38Z, the
   day of the draft): the satisfier now errors on BOTH launch targets —
   GitLogin and ForgeLaunch each return "is a launch target, not a satisfiable
   prerequisite" (`container_deps.rs` `impl Satisfier for RealSatisfier`, the
   two guard arms), with tests
   `RealSatisfier refuses to satisfy GitLogin` / `… ForgeLaunch`; the
   order-229 known-gap allowlist was emptied (order 252, order 229). The
   satisfier additionally gained an order-234 runtime-phase gate refusing all
   container mutations while the VM is draining
   (`container_deps.rs`, the `crate::runtime_phase::container_mutations_allowed()`
   check at the head of `satisfy`) — a guard this draft did not anticipate. The
   deeper ask — a true Ctx::Forge read-only graph with in-container detection —
   remains unimplemented: the guard is still "launch targets are
   unsatisfiable", not "this process is inside a forge".
5. Vault joining the declarative image set for Build context — DONE (order
   253): `--init` pre-builds it, closing §Observation-1/3 (on-demand vault
   build+rebuild during login).
## 4. Platform Abstraction Layer (NA-04)

| HOST platform | VM/bridge mechanism | Control plane | Podman location |
|---|---|---|---|
| Linux bare (mutable) | none | unix socket (host-local control wire) | host rootless podman |
| Fedora Silverblue (immutable) | toolbox container for COMPILE only (order 239) | unix socket | host rootless podman (runtime); toolbox shares it for builds |
| Windows | WSL2 Fedora guest | hvsock (`vm-layer/src/transport_windows.rs`, `wsl.rs`); tray on host, headless in guest | in-guest podman |
| macOS | Virtualization.framework Fedora guest (`vz.rs`, stable `guest_cid`); egress via `VZNATNetworkDeviceAttachment` (`vz.rs:983,1121-1122`) → vmnet NAT `192.168.64.x`, host-side gateway `192.168.64.1` on `bridge100` — ground truth verified on the macOS host 2026-08-10/11: `192.168.64.1` is the bind target for the 657-s6g8 Metal inference sidecar's host-service ingress on that NAT net (`plan/index.yaml:37068-37088`; SLOT-6 gates `openspec/specs/inference-engine-slots/spec.md:173-208`); no GPU passthrough into the guest (Metal work stays host-side), guest CPU exposes i8mm+SME2 | virtio-vsock (`transport_macos.rs`); `~/src` mounted via virtiofs (order 193) | in-guest podman |

Uniformity claim (to ratify): the CONTAINER layer (§1.1) is byte-identical
across all four platforms because tillandsias-headless always runs adjacent to
the podman it manages (host on Linux, in-guest on WSL2/VZ). Platform
differences are confined to (a) the host↔headless transport, and (b) host-DNS
integration. The secure channel work (orders 141/142/145/184/194,
`tillandsias-secure-channel`) hardens transport (a); the vsock→podman-exec
authn gap is closed via orders 140/141 (order 137 was superseded by the
encrypted control channel; slices 1-3 of 141 landed, 4 and 6 remain —
`plan/index.yaml:967-979,1050-1055`).

## 5. Spec/Cheatsheet Patch List (NA-05)

- **P1 `openspec/specs/enclave-network/spec.md`** — Purpose says "Only the
  proxy container has external access (dual-homed)". At draft time this was
  false twice over (git-mirror upstream forwarding since order 167, plus the
  login-helper dual-home). Post-0a972411 the mirror is enclave-only, so the
  remaining divergence is the login helper's dual-home (`run_provider_login`,
  `main.rs:7589,7625`) — itself ruled an unsanctioned violation pending a
  verdict (`plan/issues/git-mirror-egress-spec-divergence-audit-2026-08-10.md`).
  Patch: enumerate the now-two-member S3 set + cite this taxonomy. Still
  unapplied as of Revision 2 (spec.md:10 unchanged; no
  `openspec/specs/network-scenarios/` exists).
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

1. **Vault missing from `--init`** — was CONFIRMED at source at draft time
   (the then-current `run_init` image list lacked vault; on-demand build lived
   in the login path). RESOLVED per the predicted fix direction (§3 item 5):
   order 253 / commit 8b6c7031 put vault in `run_init`'s declarative set
   (`main.rs:5884-5895`); the login-path build is a fail-soft fallback only
   (`vault_bootstrap.rs:1410-1426`).
2. **HTTP 401 from `gh auth login`** — the audit's network exoneration was
   CORRECT: the failure was never in the proxy path. RESOLVED — root cause was
   the container pty, not credentials or network: gh's interactive masked
   prompt switched the pty to raw char-at-a-time mode, so a token pasted over
   `podman exec -it` picked up bracketed-paste escape bytes or truncation; gh
   validated garbage and GitHub returned 401 Bad credentials
   (`main.rs:7193-7205`). Fix: cooked-mode shell `read -rs` (no bracketed
   paste) piped to `gh auth login --with-token`, plus a non-interactive
   `--with-token` stdin lane; the interactive gh prompt is deliberately
   avoided (`main.rs:7206-7230`, wiring `main.rs:518-519`, mode selection
   `main.rs:7416-7430`). Note the draft's mechanism detail is now obsolete:
   squid's `no_bump` ACL no longer exists — everything except GitHub release
   assets is spliced end-to-end (`squid.conf:64-80`), so tokens never transit
   the bump CA when proxied either.
3. **Vault rebuilds on repeated login** — RESOLVED by the same order-253
   change, exactly as predicted: vault moved to the init/Build context and
   `build_vault_image` early-returns when the init-built identity tag exists
   (`vault_bootstrap.rs:1410-1423`, guarded by
   `tillandsias_podman::image_exists_sync`), so login is zero-build on an
   initialized runtime and the rebuild disappeared from the login path by
   construction.

## 7. Follow-up packets proposed

- Wire vault into the `--init` declarative image set (§3.5, §6.1) — DONE
  (order 253, commit 8b6c7031, 2026-07-09); it did close two of three observed
  failures structurally.
- RuntimeContext enum in container_deps (§3) — still open: order 252 completed
  with launch-target guards + the second ForgeLaunch target, not context
  modeling.
- P5 network-scenarios spec + `--network`-site litmus — still open (no
  `openspec/specs/network-scenarios/` exists).
- P6 build-egress decision (squid :3129 vs `--dns 8.8.8.8`) — still open; note
  the dev-build flow already runs its own separate squid cache on
  `127.0.0.1:3129` (`build.sh:355-411`), distinct from the proxy image's
  orphaned :3129.


---

# REVISION PASS 2 — Windows/WSL slice (2026-08-23, yolanda, order 245 cycle-scoped claim)

Scope: the Windows/WSL claims the 2026-07-14 GPT verification flagged as
predating current reality ("mirrored WSL networking documentation" on the
revision list), verified against code at windows-next HEAD and LIVE state on
yolanda (the fleet's reference dual-locus Windows host). Findings, not
opinions; each carries its source. Non-Windows items on the revision list
(RuntimeLane, ForgeLaunch modeling, Vault-in-init, cooked-read GitHub-login)
are NOT revised here — location pointers only, for the host that owns them.

## W1. The fleet's Windows reality is NAT + DNS-tunnel, not mirrored — MEASURED

`wslinfo --networking-mode` on yolanda: **`nat`**. No `%USERPROFILE%\.wslconfig`
exists on this host, so WSL defaults apply — and any documentation or code
comment assuming `networkingMode=mirrored` describes a configuration no fleet
Windows host is known to run. Guest DNS is the WSL DNS tunnel: `/etc/resolv.conf`
carries `nameserver 10.255.255.254` (dnsTunneling default), NOT the classic
NAT-gateway 172.x address. Consequence for §2/§4: `ensure_enclave_host_dns`'s
WSL arm must be read against the tunnel address, and "mirrored resolv.conf
handling" (draft line ~123) is a misnomer on current defaults — the handling
is NAT-mode DNS-tunnel handling. The mirrored-mode branch, if kept, is
speculative until a fleet host actually runs mirrored networking.

## W2. The Windows control wire is PRIVILEGE-ROUTED, two transports — the draft says one

Draft §4 row (line ~261) lists "hvsock" alone. Current code
(`crates/tillandsias-windows-tray/src/hvsocket.rs`, order 312): elevated
processes take direct **AF_HYPERV** (`open_hvsocket_stream`); standard-user
processes take the **`wsl.exe` stdio bridge** (`open_wsl_stdio_bridge`) —
two genuinely different network paths with different failure modes (the
stdio bridge is the lane the N100 `handshake: early eof` family lived in;
see plan/archive/packets-2026-08.yaml, socat CID-1/ENETUNREACH). The §4
platform matrix should carry both, with the privilege condition.

## W3. Guest-side vsock is BUILT-IN on current WSL kernels — detection caveat

`/dev/vsock` exists in the guest while `vsock` is absent from `/proc/modules`
(built into 6.18.33.2-microsoft-standard-WSL2, same packaging shift
esmeraldinha recorded for dxgkrnl in the capability audit). Any probe that
tests vsock availability by module presence false-negatives on current
kernels; device-node presence is the correct signal. (`vsock_loopback`
remains a distinct, loadable module and the historical N100 wedge.)

## W4. Detection markers verified live

`/run/WSL` (draft line ~111) is real and populated on a live guest
(interop files: `<pid>_interop`) — headless/main.rs:2872 reads it. Marker
current; no correction.

## W5. Pointers for the non-Windows revision items (NOT revised here)

- RuntimeLane: lives in `crates/tillandsias-podman/src/lib.rs` — the §1
  taxonomy table predates it and should be re-expressed in its terms by a
  host that can run the podman lanes.
- The draft's §1.1 CONTAINER matrix and §3 ForgeLaunch modeling: forge-lane
  facts; a linux host with podman must re-verify.
- Vault-in-init and the cooked-read GitHub-login fix: touch the credential
  flow documented in §2; the 246a/246b split children own the deeper pass.

Cross-reference per the epic's rule: W2's failure-mode citation IS 606-9wqd
territory seen from the Windows side; cited, not re-derived.

## L1. Citation drift measured and repaired in §1/§1.1 — 2026-08-25, yoga (linux slice)

W5 handed the non-Windows revision items to "a linux host with podman". Taking
§1 and §1.1, the finding is not that a fact had changed — every claim in the
CONTAINER matrix re-verified true — but that **every `file:line` citation
supporting them pointed at unrelated code.**

MEASURED at `linux-next` 23671a86e, by resolving each cited span:

| Cited in the draft | What is actually there now | The real anchor |
|---|---|---|
| `main.rs:1136-1145` (ENCLAVE_ONLY_NET) | a `format_age_secs` branch | `const ENCLAVE_ONLY_NET` (~1597), used by `build_git_run_args` |
| `main.rs:2973-2975` (git_mirror_service_identity) | an `ensure tillandsias-egress network` refusal | `fn git_mirror_service_identity` (~3997) |
| `main.rs:2553-2554` (`--hostname proxy`) | an unrelated early `return Vec::new()` | `fn build_proxy_run_args` (~3345) |
| `main.rs:2052` (ensure_enclave_network) | — | `fn ensure_enclave_network` (~2801) |
| `main.rs:9656-9666`, `:10103-10190`, `:18863-18877` (browser) | — | `fn build_project_browser_spec` (~11751); the `SYS_CHROOT` assertion is ~22357 |

The drift is TOTAL, not a small offset: `main.rs` has grown past 22,000 lines
and these citations are weeks old. A reader following one of them does not
merely waste time — they land in plausible-looking neighbouring code and may
"verify" a claim against something unrelated, which is worse than an obviously
dead link.

REPAIRED by anchoring §1/§1.1 on SYMBOL NAMES (`main.rs` `build_git_run_args`)
rather than line numbers. A symbol survives every edit that does not rename it,
and a rename is a real event worth noticing; a line number is invalidated by
any insertion above it. This is order 797-8dzt's lesson — source slices bounded
by symbol names, not offsets — applied to prose. Doc-wide the line-number
citation count drops 90 → 80; §1/§1.1 now has none into `main.rs`.

Also removed: the `plan/index.yaml:967-979,...` citation for the secure
control wire. Line numbers into the ledger are guaranteed to rot, because
compaction rewrites that file by design (it folded 32 fragments into it twice
this week alone). Orders are the stable identity there and are what the ledger
itself tells you to cite.

NOT REPAIRED, and named so the next host can pick it up: 80 line-number
citations remain across §2-§7 and 20 distinct files. They were not touched
because this slice's mandate was §1/§1.1, and because a bulk rewrite without
re-verifying each claim would replace wrong-but-honest citations with
confident-looking ones — the same trade this document already made once.
NA-05's exit criterion asks for a patch list with "specific file:line
references", which is exactly the requirement that produced this rot; whoever
drives ratification should decide whether that criterion should say "specific
file:symbol references" instead.

Filed alongside: the systemic version of this — nothing in the tree checks that
a `plan/issues/` citation still resolves, so an audit's evidence rots silently
while the document keeps reading as verified.

## L2. NA-03 re-verified and re-anchored — 2026-08-30, lenovinha (linux slice)

Cycle-scoped claim on a `multi_cycle` packet; `phase` stays `review`, NOT
closed. W5 handed §3 (ForgeLaunch dependency modeling) to "a linux host with
podman"; this is that host taking it. NA-03 is one of the three criteria the
2026-07-14 GPT verification FAILED, which is why it was picked over the
untouched sections.

Method is §L1's, and it is the whole point: **verify the CLAIM first, then fix
the citation.** A bulk re-anchoring without re-verification would trade
wrong-but-honest citations for confident-looking ones.

### The substantive finding: a sixth edge, and a node the document does not have

`Service::ForgeLaunch`'s `DEPS` entry carries SIX edges. The draft lists five.
The sixth is `Service::NixCache`, added by **order 801-vm4p** so the nix cache
rides the forge-launch graph and is ensured wherever a forge comes up. Its
ensure SKIPS with `Ok` on a host with neither nix nor a store, which is exactly
why it could be added to every lane's prerequisites without breaking one.

`NixCache` is also a `Service` variant the draft's graph description omits
entirely, with its own edges (`EnclaveNetwork`, `CaBundle`). For a section
whose subject IS the dependency graph, an unlisted node is a **content** gap,
not citation rot — and it is the kind of drift `progress_summary` predicted
when it said the draft "predates … ForgeLaunch dependency modeling".

### The second finding: the order-252 convergence changed shape

The old text said both tray and CLI launch "route through" `ensure_forge_launch`
and cited TWO locations, which reads as two parallel call sites. There is now
exactly ONE production call site, inside `ensure_enclave_for_project`, and the
CLI reaches it transitively — `run_forge_agent_cli_mode` calls
`ensure_enclave_for_project`. The order-252 property still holds and is in fact
stronger: it is enforced by convergence rather than by two callers agreeing.
Recorded because "both routes go through X" and "there is one X" are different
architectural statements and a verifier checking the old sentence against the
tree would find two citations resolving to unrelated code.

### Citation drift in §3: total, as in §1

Ten citations checked, ten wrong. Not an offset — the same "lands in plausible
neighbouring code" hazard §L1 named:

| cited | claimed | actually at |
|---|---|---|
| `container_deps.rs:43` | `Service::ForgeLaunch` | `:48` | <!-- cite-ok: the drifted line number IS the evidence; this table exists to record what each stale citation pointed at -->
| `container_deps.rs:84-98` | the ForgeLaunch edge list | edge block starts `:97`; the range covers GitLogin + NixCache edges | <!-- cite-ok: the drifted line number IS the evidence; this table exists to record what each stale citation pointed at -->
| `container_deps.rs:210-226` | `ensure_forge_launch` | `pub fn` at `:230`; the range is the tail of `ensure_git_login` | <!-- cite-ok: the drifted line number IS the evidence; this table exists to record what each stale citation pointed at -->
| `container_deps.rs:228-234` | `ensure_service_catalog` | `:248`/`:250` | <!-- cite-ok: the drifted line number IS the evidence; this table exists to record what each stale citation pointed at -->
| `container_deps.rs:319-326` | the launch-target refusal | `:341`/`:345`; the range is the satisfier's dispatch `match` | <!-- cite-ok: the drifted line number IS the evidence; this table exists to record what each stale citation pointed at -->
| `container_deps.rs:547-565` | the refusal tests | `:685`/`:696`; the range is `dependency_graph_is_complete_and_acyclic` | <!-- cite-ok: the drifted line number IS the evidence; this table exists to record what each stale citation pointed at -->
| `container_deps.rs:293-301` | the order-234 drain gate | `:314-317`; **the range is the `RealSatisfier` doc comment** | <!-- cite-ok: the drifted line number IS the evidence; this table exists to record what each stale citation pointed at -->
| `main.rs:11067` | the shared-wrapper route | `:12884` | <!-- cite-ok: the drifted line number IS the evidence; this table exists to record what each stale citation pointed at -->
| `main.rs:16610-16611` | the CLI route | a `tier` assertion in a test | <!-- cite-ok: the drifted line number IS the evidence; this table exists to record what each stale citation pointed at -->
| `main.rs:6950-6962` | status-check building 8 images | a `containers.conf` write | <!-- cite-ok: the drifted line number IS the evidence; this table exists to record what each stale citation pointed at -->
| `main.rs:5884-5895` | vault `--init` pre-build | `sanitize_hostname` for a forge name | <!-- cite-ok: the drifted line number IS the evidence; this table exists to record what each stale citation pointed at -->
| `podman/src/lib.rs:105-109` | `RuntimeLane` | enum `:76`, classifier `:97` | <!-- cite-ok: the drifted line number IS the evidence; this table exists to record what each stale citation pointed at -->

The `:293-301` row is the one to keep in mind when judging whether this matters:
a reader checking "is there a drain gate?" lands on a struct's doc comment about
dependency ORDER and can come away satisfied that they looked.

`main.rs` is now 24,668 lines — up from the ~22,000 §L1 measured five days ago.
Line citations into it do not decay, they are void.

### Also removed

The two `plan/index.yaml:72xx` citations (order-229 allowlist, order-252
satisfier). Line numbers into the ledger rot by design, per §L1; replaced with
the order numbers, which are the ledger's own stable identity.

### Not done here

§2, §4, §5, §6, §7 still carry line-number citations, and the count is now
lower than §L1's 80 only by the twelve fixed above. They were left because this
slice's mandate was §3 and because re-verifying a claim is the expensive half —
it is what makes the re-anchoring honest, and it does not compress.

NA-05's exit criterion still asks for a patch list with "specific file:line
references". §L1 flagged that this is the requirement that produced the rot;
after a second section it is worth stating plainly: **whoever drives
ratification should change NA-05 to `file:symbol`**, because the criterion as
written mandates the defect. That is a change to an exit criterion, so it is
the packet owner's call, not this slice's.
