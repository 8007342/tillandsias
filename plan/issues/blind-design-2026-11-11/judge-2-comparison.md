# Comparison — judge 2: four blind designs (reified) vs. the current Tillandsias

Protocol: `rubric.md` in this directory was written before any design, answer,
audit finding or source file was read. **X = blind-reified** (best single blind
design per row, capped at 2 where the four contradict without resolution).
**Y = current system**, read at `e886f596c` on `work/2080-3tzc-l5def`, read-only.
I did not read `judge-1/`. D = design score, I = implemented score, 0–4 each;
they are never added together. X.I is 0 on every row by construction.

Read path: forge-plan MCP first (`methodology_ask`, `spec_answer`,
`plan_status`, `plan_query`). `spec_answer` returned retrieval-only envelopes
(synthesis discarded or timed out) three times, so the cited spans and the code
were read from files — fallback reason **unavailable** for synthesis,
**verification** for every security claim below.

Regime of every live number: host macuahuitl, Fedora, rootless podman, tray
v56.11.10.1, 2026-11-11, one Claude forge running. One sample; not a trend.

## 1. Scores

### 1.1 Totals per area

| Area | rows | X.D | Y.D | max D | Y.I | max I |
|---|---|---|---|---|---|---|
| A Product promise | 6 (A7 excluded: contaminated) | 16 | 13 | 24 | 17 | 24 |
| B Per-platform obligations | 6 | 17 | 16 | 24 | 18 | 24 |
| C Credential hygiene | 9 | 30 | 23 | 36 | 24 | 36 |
| D Observability for forge agents | 7 | 27 | 17 | 28 | 18 | 28 |
| E Supply-chain provenance | 7 | 20 | 16 | 28 | 15 | 28 |
| F Earned complexity (D only) | 6 | 20 | 8 | 24 | — | — |
| G Language direction | 4 | 12 | 6 | 16 | 5 | 12 (G1 is a measurement) |
| **Total** | 45 | **142** | **99** | 180 | **97** | 152 |

X.I = 0 / 152. Read the table as: on paper the blind designs are 43 points
better *as designs*; the current system is 97 points better *as a thing that
exists*. Neither number converts into the other. The 27/28 for X in area D is a
paper design that has never met an incident; treat it as an upper bound.

### 1.2 Row scores and evidence

**A. Product promise**

| Row | X.D | Y.D | Y.I | Evidence |
|---|---|---|---|---|
| A1 idle cost defined and bounded by a number | 3 | 1 | 1 | X: designer A defines states S0–S3, per-platform instruments and a red-first gate; every number is `[proposed]`, unmeasured, held on OQ-1/OQ-2. Y: no numeric tray or idle budget in any spec (my grep and the membrane both: NOT FOUND). Live: tray Pss 16.6 MB / Rss 31.6 MB, 36 threads, about 22 context switches per second across threads, 7 s CPU in 1707 s. |
| A2 event-driven, no unapproved polling | 3 | 2 | 2 | "No polling" itself is contaminated (memory headline; A disclosed it). Credit only for what X adds: a build-time gate on timer APIs plus a wakeup test seen red first, and a timer inventory. Y: the ruling exists and conversions happened (inotifyd in `images/git/entrypoint.sh`, blocking recv in `lane_events`), but there is no inventory and `memory_stall_watch::INTERVAL` is a 15 s resident loop that lists containers (240 passes an hour), `PTY_HEARTBEAT_INTERVAL` 30 s, a 60 s external-logs auditor (from `spec:external-logs-layer`; not read in code). Whether the 15 s cadence was approved: UNVERIFIED. |
| A3 one action to a forge; finite failure sentences | 3 | 3 | 3 | Both have failure tables; Y's are real (`ca-key-unavailable:`, `refused:vault-unseal-key-not-tmpfs:`), X's are complete on paper. |
| A4 service inventory, each with a reason, and what stops when idle | 2 (cap) | 2 | 4 | X: four topologies (A six `regiond` services under systemd; B one gateway; security a host broker plus per-project relays; events a hub). B alone is a 4 ("which obligation breaks without it?" table). Y: eight containers up for one Claude forge (builder, vault, proxy, nix-cache, router, git, inference, forge); nothing stops while the tray runs. |
| A5 reset converges | 2 | 3 | 4 | X's private store and reset depths are `[C]`. Y: reset-is-the-baseline is exercised destructively by the smoke skills. |
| A6 degradation (no tray host, no runtime, disk full) | 3 | 2 | 3 | X: CLI fallback on a name-owner signal, admission control. Y: swap refusal and prerequisite diagnostics exist; GNOME without the extension is undecided (OQ-3). |
| A7 end-user surface | C | 3 | 2 | Every blind statement here is a ruling import. Excluded from sums. |

**B. Per-platform obligation holding**

| Row | X.D | Y.D | Y.I | Evidence |
|---|---|---|---|---|
| B1 obligations evaluable on one platform alone | 4 | 2 | 2 | X: A's "a number without a regime is not a result" and per-platform instrument table. Y: the ruling exists; no per-obligation, per-platform witness exists (same gap the 2026-11-09 comparison recorded). |
| B2 Linux | 3 | 3 | 4 | X: A depends on socket activation into rootless containers, marked `[verify]` and "needs a spike" by its own author; B (podman CLI, no daemon) is the safer blind answer. Y: running. |
| B3 macOS | 2 | 3 | 3 (UNVERIFIED live from this host) | X keeps `podman machine` on libkrun after being told the real system owns its guest; boot time on a floor host is unmeasured, machine default mounts are a known hazard its own security designer flags, and bundling needs an operator licence decision. X's one real advantage: the VM stops when idle. Y: `VmRuntime`, vsock, identity disk, share delivered into guest memory (1909-aryk); the VM never idles; the control wire ships unauthenticated by default (ready row 972-umik). |
| B4 Windows | 2 | 3 | 3 (UNVERIFIED live) | A and B disagree (podman machine on WSL vs. own imported distro); the events designer says its own `wsl.exe` uplink is fragile. Y: one dedicated distro, `wsl_lifecycle`, Hyper-V vsock. |
| B5 a per-platform witness per release | 3 | 3 | 3 | Y: `promote-stable.sh` needs a PASS per platform for the exact tag; ready row 578 records that the PASS string is written by the agents it constrains. X: per (invariant, platform) verdicts, no aggregate row. |
| B6 divergence contained | 3 | 2 | 3 | Y: three tray implementations (`tillandsias-headless/src/tray` 8.6k lines, `tillandsias-macos-tray` 19.7k, `tillandsias-windows-tray` 17.7k) and two control dispatchers whose convergence module `control_dispatch` is still marked STAGED under `#[allow(dead_code)]` from a 2026-05-25 plan. |

**C. Credential hygiene** (flow map in §3)

| Row | X.D | Y.D | Y.I | Evidence |
|---|---|---|---|---|
| C1 complete inventory | 4 | 2 | 2 | X: one lifetimes table covers every item. Y: no single inventory; milestone 590-z3jh ("every credential audited at RUNTIME") is still `ready`; the black-box audit found locations no code writes any more. |
| C2 nothing plaintext at rest | 3 | 3 | 2 | Contaminated as a goal. Note the diversity result: blind A and blind B both delivered tokens as `podman secret` (file driver, plaintext on disk) and only the security designer caught it. Y: `ca_key_store` (tmpfs plus keyring), `purge_credential_fallbacks_in`, refusal on a non-tmpfs runtime dir are real; but `scripts/tillandsias-host-push-cert.sh` keeps an AppRole document and an unencrypted ed25519 key in `~/.config` on purpose. |
| C3 forge holds no long-lived upstream credential | 3 | 2 | 3 | X: relay plus base-URL swap, with an honest labelled exception and OQ-16. Naive point: for a subscription sign-in the exception *is* the main case. Y: holds for GitHub and Cloudflare; fails for every harness — the forge entrypoint restores the OAuth document from Vault (`spec:tillandsias-vault` requirement 3f67b06a), and `images/vault/policies/claude-forge.hcl` grants `create, update, read` on the install-wide `secret/data/claude/oauth`. |
| C4 delivery channel | 4 | 3 | 3 | X (security): unix socket only. Y: nothing in argv, env, image layers (audit negative result agrees with `build_*_run_args`); 0444 files in a 0700 tmpfs directory, deliberate (`write_runtime_secret`). Ready row 590-mtgn claims provider keys still travel by env; not reproduced here, UNVERIFIED. |
| C5 trust root | 2 (cap) | 2 | 4 | X: three answers (RAM-only vault container; keyring direct; keystore-wrapped AEAD file with a rollback counter). Y: HashiCorp Vault, Shamir 1-of-1 (`images/vault/entrypoint.sh`), share and root token in the same keyring, and the host uses the root token for every call (`read_and_handover_root_token`) although `tray.hcl` exists. |
| C6 cross-forge isolation | 4 | 1 | 1 | X: one internal network per project plus per-forge socket identity; all three blind designs agree, none marked `[C]`. Y: one `tillandsias-enclave` for everything (`ENCLAVE_NET`); `enclave_network_name()` has zero callers while `spec:podman-idiomatic-patterns` names a per-project network; the mirror's `git daemon --export-all --enable=receive-pack` is anonymous by the code's own comment. |
| C7 fail-closed | 3 | 4 | 3 | The one row where Y is ahead in design: `SSH_LANE_UNWIRED_REFUSAL_URL`, "refusing a credentialed mirror", non-tmpfs refusal, wipe-not-salvage. Paid for by incidents. |
| C8 lifetime and revocation at teardown | 4 | 3 | 2 | Y: per-launch AppRole, 1 h tokens renewed to 24 h, 30-minute push certs. Residue is not reaped: a dead host-push AppRole, a 10-year CA key in `~/.cache`, a 527 MB Vault audit log. |
| C9 egress control | 3 | 3 | 4 | X: CONNECT allowlist, no interception — cannot constrain paths on an allowlisted host. Y: squid ssl-bump with a CA key in the proxy container, enclave `internal`, only the proxy dual-homed (606-9wqd measured it). Different trades; neither dominates. |

**D. Observability for forge agents**

| Row | X.D | Y.D | Y.I | Evidence |
|---|---|---|---|---|
| D1 typed, versioned, origin on every record | 4 | 2 | 2 | X: hub-stamped `source`, schema registry, no free-text field. Y: `ControlMessage::{Subscribe, VmStatusPush, LoginStatePush, FlowStatePush, ProgressPush}` are typed, but `Failed { reason: String }` and MCP `notifications/message` carry free text. |
| D2 propagation with loss semantics | 4 | 2 | 3 | X: snapshot plus deltas, `(boot, seq)`, `hub.gap`. Y: post-receive datagram → `lane_events::listen_for_project` → lane notification; a dropped datagram is silent. |
| D3 one agent interface for "what is happening / when may I retry" | 4 | 2 | 2 | Y's lane MCP socket lists `browser.open`, `preview.{publish,status,logs,reload,stop}`, `publish.local`, `studio.*`, `toolchain.prepare`, `image.generate`, `webstudio.open`. No status, events or wait tool. `retry_after` exists per tool, not as a shared shape. 1779-sq9g is `implemented` as research. |
| D4 visibility scoping | 4 | 3 | 3 | Scope itself was a given ruling. X adds: visibility computed by the hub from the type registry. Y: per-lane socket directory, "except the pusher's". |
| D5 logs die with the forge; no secret or PII crosses | 4 | 2 | 2 | Y: `terminal_handoff::attached_session_log_path` appends host launcher output to `log_dir()/attached-sessions/<container>.log` and keeps it; `OLLAMA_DEBUG=1`, `GIT_TRACE=1`, `DEBUG_PROXY=1` are unconditional; the external-logs tier is disk-backed. |
| D6 no new polling | 3 | 3 | 3 | X admits a wedged-but-connected hub is undetected. |
| D7 one curated status line | 4 | 3 | 3 | Ruling-given; X adds a reducer and a finite sentence table. |

About 3k lines of `tillandsias-logging` (`aggregator`, `sampler`, `span_context`,
`surface`, `schema_validation`) name types with no consumer outside the crate; the
product uses `ImageBuildEvent`, `ImageBuildEventWriter`, `CardinalityAnalyzer`
and `BudgetEnforcer`. A ledger row already says so for `query`.

**E. Supply-chain provenance**

| Row | X.D | Y.D | Y.I | Evidence |
|---|---|---|---|---|
| E1 cheatsheet provenance annotated, gate on absence | 3 | 2 | 3 | Y: 252 of 254 root cheatsheets carry `last_verified` and `sources`; 231 a Provenance section; `check-cheatsheet-sources.sh` only warns on an unfetched source. |
| E2 provenance verified | 3 | 1 | 1 | Y: the verbatim source layer is a tombstone (`cheatsheet-sources/.gitkeep-tombstone`); 185 of 254 were last verified in 2026-04 or 2026-05; ready row 588-8mh8 says the tooling renders the absence as a verification badge. X: a page hash is unstable for dynamic pages — naive, but a mechanism. |
| E3 images pinned or attested | 3 | 2 | 2 | Y builds every image locally from Containerfiles embedded in a cosign-signed binary. `images/image-pins.yaml` has 4 digests; the bases of vault (`hashicorp/vault:1.18`), git (`alpine:3.20`, plus `hashicorp/vault:1.18` for its agent), proxy (`alpine:3.22`), router (`caddy:2-alpine`), inference and forge (`fedora-minimal:44`) are tags. X: pull prebuilt by digest with a sigstore policy; TUF roles are heavy for this scale. |
| E4 local models: origin, hash, licence before first use | 4 | 3 | 3 | Y is strong for studio weights (`restricted_fetch`: suffix allowlist, sha256, register, single-use consent) and absent for LLMs (`ollama pull "$_model"` by tag in `images/inference/entrypoint.sh`); the model cache is mounted `rw` into inference. |
| E5 per-project licence acceptance | 2 | 4 | 3 | Contaminated: the `accept-licence` skill description gave X the whole mechanism. X adds only the validity tuple and supersede/revoke. Y: `licence_consent` (SSHSIG, licence text hash, obligations spec), wired through `studio_key` → `admits_restricted`. |
| E6 forge tooling pinned, fetch failure defined | 2 | 2 | 2 | Both thin. |
| E7 release signed and the installer verifies | 3 | 2 | 1 | Y signs (cosign keyless, SHA256SUMS) and `scripts/install.sh` verifies nothing cryptographic and skips the checksum in three cases (ready row 1068-phrh, p2). |

**F. Earned complexity** (D only)

| Row | X | Y | Evidence |
|---|---|---|---|
| F1 every component names its obligation | 4 | 1 | Y: 29 crates, 186 specs (28,832 lines; 45 with no `Requirement:` heading), 67 open changes, `tillandsias-headless/src/main.rs` 41,581 lines, `vault_bootstrap.rs` 12,000. |
| F2 no duplicate mechanisms | 2 (cap) | 1 | Y: two control dispatchers; three log systems; two git transports on one mirror (anonymous 9418, sshd 2222); two cheatsheet trees (254 files each). X: three vault answers, two event transports. |
| F3 product separated from process | 3 | 1 | Y: `tillandsias-plan` is the second-largest crate (69,654 lines) in the product workspace; 892 scripts, 539 named `test-*`; the shipped mirror's `pre-receive-hook.sh` validates plan-ledger YAML. |
| F4 spec and code agree | 3 | 2 | Y: README says the project "is mounted" and "credentials stay outside the forge"; both are false today. Credit: the ledger records many such gaps itself (577, 1252-qyii, 588-8mh8). |
| F5 enumerable in an hour | 4 | 1 | Y's own tool describes the corpus as about 950k tokens, "too big for any context". |
| F6 deletion test | 4 | 2 | X: B's "services considered and cut". Y: candidates exist and some are filed; none are deleted. |

**G. Language direction**

Measured on tracked files today:

| Language | files | lines | where |
|---|---|---|---|
| bash | 1,024 | 210,854 | `scripts/` 892 files (top level about 170k lines), `images/` 107 files / 25,363 lines (shipped inside containers: `images/default/lib-common.sh` 6,032, `images/git/entrypoint.sh` 980, `pre-receive-hook.sh` 794) |
| python | 4 | 1,208 | 3 runtime files in studio images (1,117 lines) against `tlatoani_hard_no_python.rule`; 1 evidence file |
| Lua | 306 | 42,777 | 289 in `scripts/`; 9 in crates |
| Rust | 414 | 364,247 | |
| Go | 1 | 16 | |
| PowerShell | 11 | 3,307 | |

Trend (commit nearest each date): bash 308 files / about 49k lines 90 days ago →
995 / about 202k 30 days ago → 1,033 / about 212k 7 days ago → 1,024 / 210,854
today. Lua 0 → 117 → 241 → 306. Bash quadrupled in the quarter and has dipped
under 1% in the last week. Older line counts are approximate (batch output
includes one header line per file).

| Row | X.D | Y.D | Y.I | Evidence |
|---|---|---|---|---|
| G1 footprint | 3 | 1 | — | X needs zero shell; naive about 25k lines of entrypoints around third-party daemons (Vault Agent, squid, ollama). |
| G2 a ratchet that makes it fall | 3 | 2 | 2 | Y's floors count sites (`jq-callsite-floor`, `pipe-site-floor`, `shell-decider-floor`), not lines; nothing bounds the total. |
| G3 shipped runtime path free of bash/python | 3 | 1 | 1 | Y: install is `curl … | bash`; every container entrypoint is bash. |
| G4 a reason per language | 3 | 2 | 2 | Y: Go is in the direction and absent in the tree; Lua replaces dev shell, not product policy. X: A gives a reason for Go (network daemons); B argues Rust only. |

## 2. Black-box audit reconciliation (every High and Medium, from code)

| Finding | Verdict | Symbol read | Note |
|---|---|---|---|
| H1 root token, only unseal share and CA keys readable by any same-uid process | **CONFIRMED** | `keychain_set_blocking("vault-root-token-v1", …)` in `persist_healed_root_token` and the fresh-init handover; `read_and_handover_root_token` called by every host Vault operation; `secret_shares:1, secret_threshold:1` in `images/vault/entrypoint.sh`; `vault_host_publish_arg` | The keyring is the store the ruling allows, so severity turns on OQ-17. Persisting *root* is not required by any ruling. The audit's "do not publish on loopback" ignores the stated reason (a rootless host cannot route to the bridge). |
| H2 anonymous read-write git daemon on the shared network | **CONFIRMED** (reachability still not demonstrated live) | `git daemon --export-all --enable=receive-pack --listen=0.0.0.0` in `images/git/entrypoint.sh`; comments in `build_git_run_args` call it "the anonymous git daemon … NO authentication" | Per-project DNS alias (659-8faj) is obscurity on a /24. Authenticated transport: 322 archived as design, 451 `pending`, blocked on a parked row. |
| H3 router holds the tray control-socket directory read-write | **CONFIRMED, severity reduced to Medium** | `build_router_run_args` binds `control_socket_dir()` at `/run/host/tillandsias:rw` (already narrowed by 2007-rtky); `control_dispatch::decide_route` | On the unix transport `DeliverCredentials`, `GetVaultHandover` and the PTY family are `Unsupported`. Reachable: `IssueWebSession`, `EvictProject`, `VmShutdownRequest`, `CloudRefreshRequest`, `Subscribe`, `McpFrame`, `*LoginStored`. The Caddy admin worry is **refuted from config**: `admin localhost:2019` in `base.Caddyfile`. |
| M1 runtime secret files 0444 | **CONFIRMED, deliberate** | `write_runtime_secret`, `write_unseal_key_file` (0444 file, 0700 tmpfs directory); tests pin `0o444` | A fixture pins the symptom as a contract. |
| M2 long-lived plaintext credentials outside Vault | **CONFIRMED** for the host-push AppRole and key; **not reproducible from code** for `~/.cache/tillandsias/ca-key.pem` | `scripts/tillandsias-host-push-cert.sh` ("WHY THE KEYRING IS NOT ON THIS PATH"); no writer of `ca-key.pem` in the tree, only history (`a53eabb36`, `e534c5762`) | The first contradicts `no-plaintext-credentials-at-rest`. The second is residue no purge covers. |
| M3 SELinux off everywhere; no memory limits | **CONFIRMED** for `label=disable` (56 sites); **partly refuted** for memory | `forge_budget` emits `--memory` and `--memory-reservation` for forges | Services have no limit. Ready row 1118-zzs4 would make `label=disable` *mandatory*; 1252-qyii wants it retired. The ledger disagrees with itself. |
| M4 unseal mismatch wipes the store | **CONFIRMED, intended** | `images/vault/entrypoint.sh` "wrong key" path; ruling `vault-is-thrown-away-not-recovered` | The audit's "move the old store aside" contradicts the ruling. Valid residue: the cause of today's mismatch is unexplained and was a log line only. |
| M5 debug logging on in production | **CONFIRMED, unconditional** | `build_proxy_run_args` (`DEBUG_PROXY=1`), `build_git_run_args` (`GIT_TRACE=1`), inference args (`OLLAMA_DEBUG=1`); a test asserts `DEBUG_PROXY=1` | |
| M6 one flat network | **CONFIRMED** | `ENCLAVE_NET`, `ENCLAVE_ONLY_NET`; `enclave_network_name` unused | Same root as H2. |

Lows checked in passing: L1 confirmed as persistence, **refuted as content**
(the file is the host launcher's diverted stdout/stderr, not the agent
transcript); L4 confirmed (`lane_events` sets 0666; `/run/vault-handover`
`mode=0777`); L5 confirmed (`models:rw`).

## 3. Credential flow, end to end (current system)

| Credential | Minted | Stored | Delivered | Who can read it |
|---|---|---|---|---|
| Vault unseal share (1 of 1) | Vault init in the container | OS keyring `vault-shamir-share-v1` (Linux); macOS Keychain, sent over vsock to guest memory | 0444 file in a 0700 tmpfs directory, bind-mounted into the vault container | any same-uid host process; vault container |
| Vault root token | Vault init, or `generate-root` heal | keyring `vault-root-token-v1`; memoized in the tray | never to a container; used by the host for policy, AppRole, KV | any same-uid host process |
| Enclave intermediate CA key | `openssl req` from the launcher | keyring `ca-key:intermediate.key`; tmpfs `keys/` | 0444 file into the proxy (ssl-bump) | same-uid; proxy container |
| Preview CA key (localhost-constrained) | launcher | keyring; tmpfs | host only | same-uid |
| Vault TLS leaf key | launcher | tmpfs only, re-minted after reboot | 0444 file into vault | same-uid; vault container |
| GitHub user token and refresh token | device flow from the tray | Vault `secret/github/token` | read by the mirror's credential helper with its Vault Agent token | mirror container (policy `git-mirror`); root-token holder |
| Mirror AppRole (role_id, secret_id) | host, per launch | tmpfs runtime file | bind at `/run/secrets/vault-approle`; Vault Agent writes a 1 h token to `/tmp/tillandsias-vault-token` | mirror container, which also serves the anonymous daemon |
| Mirror signer AppRole | host | tmpfs | second document, second sink | mirror container |
| Harness documents (Claude, Codex, Antigravity, OpenCode; Gemini key) | the operator's sign-in in a login container | Vault `secret/<harness>/…`, install-wide | forge entrypoint restores them into the forge home using a per-harness Vault token | **the agent**; every forge of that harness in any project; root-token holder |
| Forge Vault token | host | tmpfs file | bind into the forge | the agent |
| Host-push AppRole and ssh key | host, at provision | `~/.config/tillandsias/host-push/*.approle.json` and `*.ed25519`, plaintext 0600 | read by `tillandsias-host-push-cert.sh` at push time | same-uid, indefinitely |
| Host-push ssh certificate | Vault `ssh-client-signer`, 30 minutes | same directory | ssh to the mirror's 2222 | well constrained (force-command, source-address) |
| Cloudflare sign-in | PKCE from the tray | Vault | never to a forge; read-only tools over the MCP socket | host |
| Approval signer key | per project | hardware or Vault-sealed software key | — | host |
| Nix cache signing key | — | `~/.local/share/tillandsias/nix-cache`, 0600 plaintext | into nix-cache | same-uid |
| Legacy "Tillandsias CA" root key | an older build | `~/.cache/tillandsias/ca-key.pem` | none | same-uid; nothing deletes it |

Count of delivery mechanisms (the security designer's L2 test): keyring item,
tmpfs bind file, Vault Agent sink, entrypoint restore into home, plaintext
config file, vsock frame. Six.

## 4. Diversity among the blind designs (the disagreement is the information)

| Decision | A | B | Security | Events | Who is right |
|---|---|---|---|---|---|
| Supervisor | systemd/Quadlet in the substrate | none; reconcile on each invocation | host broker | hub beside podman | B for Linux today (no spike needed); A's socket activation is the only answer to "zero cost when idle" and is unproven |
| Supporting services | six from one Go image | one Rust gateway | per-project relays | — | B on count; security on blast radius. B's own escape hatch (same binary, `--role`) reconciles them |
| Long-lived secrets | OS keychain → RAM vault container | OS keyring direct | keystore-wrapped AEAD file | — | B is the least machinery that satisfies the ruling |
| Forge identity | bearer token valid on one network | network interface | per-forge socket | socket | security/events: socket survives several forges per project; B withdrew its own answer at reification |
| Token delivery (blind) | podman secret | podman secret | socket only | — | security; A and B were wrong before reification |
| macOS/Windows substrate | podman machine | podman machine / own distro | podman machine, project-only mounts | vsock | unresolved; nobody measured |
| Images | pull by digest | pull by digest, never build locally | pull, verify twice | — | agree, uncontaminated, and against Y |
| Logs | journald ring | `podman logs` on demand | — | tmpfs logs plus typed events | events |

Agreements that are uncontaminated and against the current system: per-project
internal networks; no credential in the forge by default; prebuilt images pulled
by digest; one count of supporting services guarded by a measure.

## 5. Shared weaknesses (suspect the obligation text or the open questions)

- Nobody has a measured idle number. X proposes, Y has none. OQ-1 and OQ-2 block both.
- Nobody solves a subscription sign-in without a credential in the forge. X labels the exception; Y hides it behind "capabilities, never credentials".
- Same-uid host process (OQ-17) defeats every design here, blind included: all of them end at an unlocked keyring.
- macOS and Windows: X never ran, Y could not be witnessed from this host. Every B3/B4 number above is from text.
- Egress: an allowlisted host is an exfiltration path in both.
- Cheatsheet provenance: neither verifies that the cited page still says what the cheatsheet says.

## 6. Top 10 learnings

1. **The current system's cross-project boundary is a hostname.** One network, an anonymous writable git daemon per project, a privileged relay behind it. The code says so in its own comments and the fix has been `pending` behind a parked row. All three blind designs put a network per project there without being told to.
2. **"Credentials stay outside the forge" is false for the harness that matters**, and any Claude forge can *overwrite* the install-wide sign-in document (`claude-forge.hcl`: create, update). That is an integrity path from one prompt-injected project into every later session.
3. **The tray is a root-token holder.** A `tray` policy exists and the host does not use it. Dropping root after bootstrap is cheap and independent of OQ-17.
4. **Two of three blind designers chose `podman secret`.** Independent designers reproduce the trap the operator already ruled on; the ruling earns its place as a guard, not a memory.
5. **The ledger knows most of this.** Installer verification (1068-phrh), SELinux (1252-qyii), cheatsheet provenance (588-8mh8), unauthenticated control wire (972-umik), the credential audit milestone (590-z3jh) are all `ready`, several since July. The gap is throughput on security rows, not discovery. A blind audit that rediscovers filed rows is measuring the queue.
6. **Bash quadrupled in 90 days while the direction says to leave it.** The floors count call sites; the total is unbounded. Most growth is `test-*` fixtures (539 files): the gate culture is the generator.
7. **The blind event model's one rule — no free-text field in anything that crosses a boundary — buys redaction, curation, the status line and prompt-injection resistance at once.** The current system has the transport (lane MCP socket, `Subscribe` watch channels) and lacks the rule and the agent-facing read.
8. **Process machinery lives inside the product.** A 70k-line plan tool in the workspace, ledger validation in the shipped mirror hook, a spec corpus that needs a retrieval model to answer questions about itself. None of it is traceable to the product promise.
9. **Blind designs are naive exactly where predicted**: VM lifetime and boot cost, unmeasured budgets, a zero-shell rule that ignores third-party daemons, and a relay model that assumes providers permit it. Reification imported rulings; it did not test anything.
10. **Debug flags and kept launcher logs contradict the log ruling today.** `OLLAMA_DEBUG=1` is always on; attached-session files outlive the forge.

## 7. Keep from each

- **Designer A**: state-based overhead definition (S0–S3); regime on every number; "a gate never seen red does not count"; the idle ladder; one image for all first-party services.
- **Designer B**: the cut list and its test; no daemon on Linux; reconcile-as-launch; pull by digest and never build on a floor host; a count guard on supporting containers.
- **Security design**: one function builds container specs and has no secret-typed input; secrets as a type with no `Display`; identity by socket; count mechanisms, not secrets; the labelled, enumerable I2 exception; the audit checklist's "assert the population, never print a match" rules (the black-box auditor leaked two secrets by breaking them).
- **Events design**: two planes; closed field kinds; hub-stamped origin; snapshot plus deltas with a gap event; pull with a cursor and a token budget; the timer inventory as an instrument.
- **Current system**: fail-closed refusals with named causes; wipe-not-salvage; tmpfs-or-keyring key store with legacy purge; per-launch AppRole with Vault Agent renewal; 30-minute constrained push certs; `restricted_fetch` and `licence_consent`; the enclave `internal` with one dual-homed proxy; per-platform promotion evidence; own VM guest with vsock (do not trade it for `podman machine` without a measurement).

## 8. Recommended target per area

| Area | Target |
|---|---|
| A | Keep the current launch path. Adopt A's state definition and a red-first idle gate once OQ-1/OQ-2 are answered. Publish a timer inventory now; it needs no ruling. |
| B | Keep the own-guest substrate. Add per-(obligation, platform) verdicts to release evidence. Finish the dispatcher convergence or delete the staged module. |
| C | Current mechanisms plus three structural changes from X: a network per project; the forge policy read-only with harvest on the host side and the forge labelled as holding a live credential; the tray on its own policy, root revoked after bootstrap. Do not adopt a second vault design. |
| D | Current transport (lane MCP socket, watch channels) plus the events designer's envelope rules and one read tool. No new hub process until the read tool exists and is found insufficient. |
| E | Current licence gate and restricted fetch. Add: digest pins for credential-adjacent bases, the installer consuming the published signature, the same register discipline for LLM pulls. Skip TUF. |
| F | Delete before adding: the logging modules nobody outside the crate uses, the unused network-name function, the staged dispatcher, the anonymous daemon once 451 lands. Move the plan tool out of the product's build graph (whether the release binary links it: UNVERIFIED). |
| G | A line floor on `images/**/*.sh` that only falls, starting with `lib-common.sh`; no runtime python; decide whether Go is in the direction or not, because the tree says no. |

## 9. Limits of this judgement

- One judge, one pass, one host. macOS and Windows scored from text.
- Not read: the blind designs' `measures.md` beyond A's first 60 lines, `threat-model.md`, `audit-checklist.md`, events `security.md`. Their rows could move by one point.
- H2 and M6 reachability is still inferred from configuration; nobody ran the cross-project `git ls-remote`.
- My prior 3 (current ahead on credentials *in design*) was wrong except on C7.
