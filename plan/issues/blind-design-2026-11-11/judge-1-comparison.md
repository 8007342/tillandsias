# Comparison — four blind designs (reified) vs current Tillandsias — judge 1

Date 2026-11-11. One rater. Judge 2's directory was not opened. Rubric: `rubric.md`,
written before any design or the implementation was read. X = blind design as
reified; Y = current design and implementation. The labels were not blinded (the
brief names which is which), so this is an unanchored-rubric comparison, not a
blind-label one.

Reads: forge-plan `spec_answer` was asked four cross-cutting questions; every call
returned retrieval-only ("synthesis timed out" / "synthesis discarded"), so the
cited spans were read from files — fallback reason **unavailable**. Code facts
below were checked by grep on the checkout at e886f596c; nothing was built or run.
Live facts come from `blackbox-audit/out/` and are marked (live).

## 0. Contamination ledger (rows that carry no independent credit)

All four designers disclosed the injected CLAUDE.md + memory index + skill list.
Reification then imported operator rulings wholesale (`[R:...]` marks). So X's
agreement with Y or with a ruling on the items below is **n.i.** (non-independent):
X is given Y's score on the row and the row is left out of the "independent" totals.

| Item | Who disclosed / how it arrived | Rubric rows |
|---|---|---|
| Dedicated VM on macOS, WSL2 distro on Windows, private podman store, `~/.tillandsias` root | A `[C]`; B method §3; rulings | R4, part of T6/R6 |
| No polling, events over polls | A method ("polling cadences are disliked"); ruling | principle only in T2/E5 — mechanisms scored |
| Prompt-free installer, curated messages, one status line, icon blush, `retry_after` | rulings imported at reification | T5, E6 |
| Vault exists, wiped not recovered, no plaintext at rest | A, B, S (L13), ruling | S3 |
| OS-verified approval for cloud-cost actions | S L13; rulings | S5 |
| Per-project git mirror / relay | A, B, S | not credited as convergence |
| Cheatsheets carry provenance | S L13 ("agents' docs having provenance") | P2 |
| Licence record: verbatim text, OS-verified, committed to the project | S L13 (skill description) | P4 |
| Log scope own + children + curated global, session-only, logs die with forge | E was handed the rulings in its brief and saw the index | E3, principle in E4 |
| "A guard must assert its population" | memory title visible to S | audit rule 1 only |

Independent by the designers' own account and by my reading: no credential in the
forge with base-URL relays; identity by channel; per-project networks; pull signed
images by digest, never build locally; substrate-side supervision / reconcile from
podman labels; idle ladder; one-gateway minimalism; typed events with no free text;
`wait` as the agent primitive; timer inventory; docs as a signed bundle; the
read-only audit with three verdicts; the threat model.

## 1. Scores (0–4 per row; n.i. rows in brackets and excluded from "indep.")

### T. Tray and process model (max 24)
| Row | A | B | Y | Evidence |
|---|---|---|---|---|
| T1 overhead is a number, guarded | 3 | 3 | 2 | A §2.6 / B §7 state RSS and wakeup budgets with a CI gate, all "[proposed]". Y: no numeric budget in any spec (membrane A-Q2 NOT FOUND); `cheatsheets/architecture/transport-overhead.md` has one measured guest figure (3 ctx-switches/90 s); spec `no-terminal-flicker` Requirement 7; guard `test-tray-refresh-no-polling.sh`. |
| T2 nothing runs when nothing is launched | 3 | 4 | 2 | B's dormant mode (one blocked thread, no sockets, no children) is checkable from the text. A needs socket activation that A itself marks as needing a spike (L5). Y: VM up for the whole tray lifetime on macOS/Windows (spec `vm-provisioning-lifecycle`); resident loops `memory_stall_watch::INTERVAL` = 15 s ("lists the running containers" each pass), a 60 s sleep loop in `tray/mod.rs`, `PTY_HEARTBEAT_INTERVAL` 30 s; the tray hosts the control, msg, MCP and push-event sockets (live). |
| T3 never blocks | 3 | 3 | 3 | Both X: menu from a pushed snapshot, long work on a worker. Y: same discipline, earned through shipped freeze fixes; tie. |
| T4 lifecycle | 3 | 3 | 3 | X: convergent start, three reset depths (A), rollback manifest (B). Y: `host-state-lifecycle`, `app-lifecycle`, destructive smoke skills are real; no updater (`update-system` obsolete; `tray-self-update` 0/12 tasks); orphans after launcher death (`idle-container-reaper` 0/7). |
| T5 end-user surface | [2] | [2] | 2 | Entirely rulings on the X side. Y: rulings exist, `os-verified-approval-gates` 0/36, two Windows installer prompts tolerated. |
| T6 per-platform | 3 | 3 | 3 | X: per-platform tables, separate verdict rows. Y: three tray crates, `VmRuntime`, vsock; Intel mac / arm64 Windows refused by installers. |
| **Total /24** | **17** | **18** | **15** | indep. /20: A 15, B 16, Y 13 |

### R. Regional cloud topology and lifecycle (max 24)
| Row | A | B | Y | Evidence |
|---|---|---|---|---|
| R1 inventory with what each earns | 4 | 4 | 2 | A: six roles of one `regiond` image with idle budgets. B: one gateway and an explicit cut list. Y: spec `enclave-service-catalog` names services, but no service has a cost or a removal test; live count: vault, proxy, router (+sidecar), git per project, inference, nix-cache always or session-on, plus browser / web / studio / imagegen / audio / webkit / wrangler / warp / enclave-fetch on demand (20 dirs under `images/`). |
| R2 isolation | 4 | 3 | 2 | A, B and S each chose one internal network per project. Y: one flat `tillandsias-enclave`; spec `git-mirror-service` req c44c1dba mandates `git daemon --export-all --enable=receive-pack` on it; cross-project separation is the opaque alias from `mirror_service_hostname` (blackbox H2, M6 — reachability unverified); 55 `label=disable` sites; squid ssl-bump holds the intermediate CA key. Y's real strengths: internal network, single dual-homed proxy, cap-drop ALL, no engine socket, no host mounts (live, "what held up"). B loses a point: identity-by-interface broke under N forges per project and needed a per-instance listener at reification. |
| R3 start/stop/health/retry | 3 | 3 | 3 | Retry semantics are a ruling on both sides. Y has `image_ensure_marker` with `retry_after`, `resource_lock`, async inference launch. |
| R4 storage and state | [2] | [2] | 2 | Single root / private store are rulings or `[C]`. Y: spec says one root (`host-state-lifecycle`, downloads manifest); the live host has five (`~/.cache`, `~/.local/state`, `~/.local/share`, `~/.config`, `~/.tillandsias`), with the Vault store and a 10-year root CA key under `~/.cache` (blackbox M2, L3). |
| R5 resource floor | 4 | 3 | 2 | A: admission control with a slot formula, idle-exit services, cgroup caps. Y: no numeric floor (OQ-1); `memory.high` per forge exists (`memory_stall_watch`), service containers run with no memory limit (live M3). |
| R6 per-platform substrate | 3 | 3 | 3 | See §2: Y is right on own VM over `podman machine`. |
| **Total /24** | **20** | **18** | **14** | indep. /20: A 18, B 16, Y 12 |

### S. Security and credentials (max 28) — security-design vs Y
| Row | X | Y | Evidence |
|---|---|---|---|
| S1 threat model | 4 | 1 | X: `threat-model.md` with actors, boundaries, STRIDE rows, residuals. Y: no spec, cheatsheet or methodology file contains a threat model (grep "threat model": none); same-UID attacker and FDE are undecided (OQ-17, OQ-18). |
| S2 credential flow end to end | 4 | 3 | X: vault → broker → relay memory, lifetimes and three revocation levels in one table. Y: spec `tillandsias-vault`, per-container AppRoles via `mint_git_mirror_vault_auto_auth`, SSH CA cert for host push (30 min, force-command, source-address — live), GitHub App device flow (`gh-auth-script`). Y loses a point for the number of mechanisms: keyring items, AppRole JSON files, token files, harness credential documents restored into the forge, a host-push AppRole on disk. |
| S3 no plaintext / fail closed / wipe | [2] | 2 | Ruling on the X side. Y: the wipe path works (live M4); the ruling is violated by `host-push/*.approle.json`, an unencrypted ed25519 key and `ca-key.pem` under `~/.cache` (live M2). |
| S4 least privilege, blast radius | 4 | 2 | X: per-repo tokens, Cloudflare child tokens, the I2 exception enumerated. Y: per-harness Vault policies are good; but `vault-root-token-v1` is kept (`KEPT_CREDENTIALS` in `reset_state.rs`; `fallback_vault-root-token-v1` in `vault_bootstrap.rs`) beside the 1-of-1 unseal share, and Vault listens on host loopback (live H1); the router gets the tray control directory read-write (`/run/host/tillandsias:rw` in the router run args; H3); secret files are written `0o444` and a unit test asserts that mode (`vault_bootstrap.rs`; M1). |
| S5 consent boundary | [2] | 2 | Ruling on the X side; X's independent addition is binding the assertion to a digest of the exact action and rendering from structured fields. Y: `licence_consent.rs` and `imagegen_consent` single-use tokens are built; `os-verified-approval-gates` is 0/36. |
| S6 auditable | 4 | 2 | X: `audit-checklist.md`, three verdicts, counts not matches. Y: no single read-only audit; the ad-hoc black-box run printed an AppRole pair and a CA key into its own transcript. |
| S7 per-platform | 3 | 2 | X names the keystore, the verification API and the default-mount hazards per OS. Y: Linux strongest; `windows-git-mirror-cred-isolation` still an open change. |
| **Total /28** | **23** | **14** | indep. /20: X 19, Y 10 |

### P. Supply-chain provenance (max 24) — security-design vs Y
| Row | X | Y | Evidence |
|---|---|---|---|
| P1 images and binaries | 4 | 2 | X: one signed manifest, pull by digest, engine `policy.json`, provenance + SBOM. Y: release binary Cosign-keyless + SHA256SUMS (`binary-signing`); base images pinned by digest (`images/image-pins.yaml`, `check-image-pins.lua`); every image built locally from embedded Containerfiles (`default-image`). `scripts/install.sh` verifies SHA256 only and **continues** when `sha256sum` or `SHA256SUMS` is missing ("skipping checksum verification"); it never calls cosign. |
| P2 cheatsheet provenance | [3] | 3 | Y: `## Provenance` sections, `check-cheatsheet-sources.sh` → `tillandsias-policy check-cheatsheet-sources` with INDEX.json hashes, `cheatsheets-license-tiered`. 29 of 256 files under `cheatsheets/` have no `## Provenance` heading; an unfetched source is a warning, not an error. X's independent addition: ship the bundle by digest, mounted read-only. |
| P3 local models | 4 | 3 | Y: `images/models/licence-register.tsv` (72 rows), `licence-register-restricted.tsv` (114), `restricted_fetch.rs` (suffix allowlist, sha256, discard on mismatch, read-only studio mount). Gaps: the inference container mounts the model cache read-write and no licence text sits beside weights (live L5). X and Y agree independently on data-only formats (pickle refused). |
| P4 per-project licence acceptance | [3] | 3 | n.i. Y: `licence_consent::project_acknowledgement_dir`, `Verifier`, `GateRefusal`, skill accept-licence. X's independent additions: `unknown` licence class treated as restricted; validity tied to the artefact digest; `supersedes`. |
| P5 agent-fetched dependencies | 2 | 2 | Both weak: contained, not recorded. Y: one 119-domain allowlist for every container (`curated-egress-tiers` proposal, 0/11). |
| P6 per-platform | 2 | 3 | Y signs per platform (Windows federated OIDC, macOS code-signature check) and has three installers. |
| **Total /24** | **18** | **16** | indep. /16: X 12, Y 10 |

### E. Events and logs for forge agents (max 28) — events-design vs Y
| Row | X | Y | Evidence |
|---|---|---|---|
| E1 event model | 4 | 3 | X: envelope, hub-stamped source/seq, closed field kinds. Y: `runtime-diagnostics-stream`, `log-schema-versioning`, `diagnostic_event_emitter`, `log-schema-golden.json`. |
| E2 agent consumption | 4 | 1 | X: `state`, `events since`, `wait`, `logs`, each with a token budget. Y: host tools offer `preview.logs` only; the scoped tools are change `forge-diagnostics-scope` (1779-sq9g) at 0/7 with three `#[ignore = "red until 1779-sq9g…"]` fixtures in `mcp_socket.rs` ("the tools do not exist yet"). `retry_after` appears in individual tool replies. |
| E3 visibility scope | [2] | 2 | n.i. Y: designed in the change, not built. |
| E4 privacy and retention | 4 | 1 | Principle is a ruling; X's independent content is "no free text in any event" and the list of copies nobody designed. Y: `terminal_handoff` writes transcripts to `attached-sessions/*.log` (0644, live L1); Vault audit log 527 MB, unrotated, survives a store wipe (L2); `DEBUG_PROXY=1`, `GIT_TRACE=1`, `OLLAMA_DEBUG=1` are hard-coded in the run args and one is asserted by a test (M5); `external-logs-layer` is a disk tier. |
| E5 cost | 4 | 2 | X: bounded rings, per-producer rate limit, a timer inventory. Y: a 10 000-event ring with no persistence; no timer inventory. |
| E6 user curation | [2] | 2 | n.i. |
| E7 per-platform transport | 3 | 4 | Y is right and built: vsock on both guests, one control wire (`vsock-transport`, `tillandsias-control-wire`). X's `wsl.exe` stdio helper is the weaker option. |
| **Total /28** | **23** | **15** | indep. /20: X 19, Y 11 |

### Cross-cutting (max 20)
| | A | B | Sec | Evt | Y | Note |
|---|---|---|---|---|---|---|
| C1 earned complexity | 3 | 4 | 3 | 3 | 1 | Y: 186 specs, 20 image dirs, `main.rs` 41 581 lines, ~55 open changes, most at 0 tasks done. |
| C2 language direction | 2 | 2 | 2 | 2 | 3 | X states "no bash/python/jq" as a clean-slate wish. Y has a working ratchet: 448 `.rs`, 287 Lua under `scripts/lua`, 892 `.sh` under `scripts`, 108 `.sh` under `images` (forge entrypoints, `mcp/git-tools.sh`), 4 `.py`, 2 `.go`. |
| C3 obligation discipline | 4 | 4 | 4 | 4 | 2 | Y has req-ids and `@trace`, but the previous exercise found 0 of 1571 obligations bound to tests. |
| C4 honesty | 4 | 4 | 4 | 4 | 3 | |
| C5 falsifiability | 3 | 4 | 4 | 3 | 2 | In these areas Y lacks the checks X names (wakeup count, cross-project probe, secret-sink sweep). |
| **Total** | **16** | **18** | **17** | **16** | **11** | |

### Implemented-ness (separate, max 4 per area)
| Area | X | Y | Note |
|---|---|---|---|
| T | 0 | 3 | runs on three platforms; no budget gate |
| R | 0 | 3 | runs; several isolation pieces are open changes |
| S | 0 | 3 | Vault, AppRoles, SSH CA, device flow all live; approval gates not |
| P | 0 | 3 | signing, pins, registers, licence gate live |
| E | 0 | 2 | tray-side stream live; agent-side tools not built |
| **/20** | **0** | **14** | |

### Totals
| Area | X | Y | X indep. | Y indep. |
|---|---|---|---|---|
| Tray (A / B) | 17 / 18 of 24 | 15 | 15 / 16 of 20 | 13 |
| Cloud (A / B) | 20 / 18 of 24 | 14 | 18 / 16 of 20 | 12 |
| Security | 23 of 28 | 14 | 19 of 20 | 10 |
| Supply chain | 18 of 24 | 16 | 12 of 16 | 10 |
| Events | 23 of 28 | 15 | 19 of 20 | 11 |
| Cross-cutting | A 16, B 18, Sec 17, Evt 16 of 20 | 11 | | |
| Implemented | 0 of 20 | 14 | | |

X leads on paper in every area; the lead is large in security and events and
small in tray and supply chain. X has built nothing and measured nothing.

## 2. Diversity: where they differ and who is right

| Decision | Blind | Current | Right |
|---|---|---|---|
| Network shape | one internal network per project (A, B, Sec independently) | one flat enclave; opaque alias per mirror | **Blind.** Three designs and the live audit point the same way. Y already has `app-networks` (v0.6) and `workload-identity-plane` (v0.6); the cross-project mirror case should not wait for them. |
| Where provider credentials live | never in the forge; base-URL relay adds the token (A, B, Sec) | harness credential documents restored into the forge from Vault | **Undecided, blind is the better target.** It hinges on provider terms (OQ-16). Until then Y's forges hold live credentials and nothing labels or counts them. |
| Secret store | OS keyring only (B); AEAD file wrapped by the keystore (Sec); in-memory vault (A) | HashiCorp Vault container, root token and 1-of-1 share in the keyring | **Split.** Y's Vault earns per-container policies and the SSH CA, which B's keyring cannot give. But Y keeps the root token, which no blind design would. Keep Vault, drop the standing root token. |
| Images | pulled by digest, signed, never built on the user's host (A, B, Sec) | every image built locally from embedded Containerfiles | **Blind**, for floor hosts and reproducibility; compatible with one intentional release build a day. Operator decision. |
| VM on macOS/Windows | `podman machine` | own Fedora guest, `VmRuntime`, vsock | **Current.** Sec's own requirement ("mount only project directories, interop and automount off") is what stock `podman machine` does not give. |
| Supervisor | systemd/Quadlet in the substrate (A); no daemon, reconcile from labels (B) | the tray process owns everything; quit = stop | **B for state, A for survival.** Y's open changes (`idle-container-reaper`, `hot-upgrade-live-stack`, `tray-self-update`) are each re-deriving "actual state lives in podman labels; adopt on start". A's socket activation is unproven rootless. |
| Idle | VM and services stop by themselves (A); nothing up when nothing launched (B) | VM up for the tray's lifetime | **Blind**, subject to OQ-2. |
| Service count | 1 (B) or 6 (A) | ~6 standing + ~10 on demand | **Neither.** B's single gateway merges credential holder and egress proxy, which Sec and Y both split. After reification A and B each had to add appliances, an isolated browser and an approval dialog, so part of Y's count is ruling-driven. What Y lacks is a cost and a removal test per service. |
| TLS interception | none (A, B) | squid ssl-bump with an intermediate CA | **Blind as default.** `curated-egress-tiers` already says "keeping TLS intact". |
| Agent event access | pull with cursor, token budget, blocking `wait` | designed (`forge-diagnostics-scope`), not built | **Blind**, and it fits inside Y's change. |
| Host↔guest transport | vsock, else `wsl.exe` stdio; loopback TCP rejected (Evt). Loopback TCP chosen (B) | vsock on both | **Current.** B's loopback control port is the weakest of the three. |
| Podman secrets | rejected: file driver is plaintext (A, B, Sec, and the ruling) | open change `podman-secrets-migration` proposes moving to them | **Blind.** That change conflicts with `no-plaintext-credentials-at-rest` and should be closed or rewritten. |

## 3. Shared weaknesses (suspect the shared input)

1. **Nobody has a number for "near-zero".** X proposes numbers; Y has none; both wait on OQ-1 and OQ-2. The promise is unmeasurable as written.
2. **Agent-fetched dependencies** (P5): every design contains rather than records them.
3. **Same-UID attacker**: all blind designs put it out of scope and Y has no statement. The live audit shows it is the cheapest real attack (H1).
4. **Language direction**: X states the end state with no path; Y has a path and 1000 shell files. Neither gives a date or an order for the product path (forge entrypoints, MCP shims).
5. **Audit after forge removal** (OQ-6..9): unresolved in all five subjects; Y meanwhile keeps a 527 MB Vault audit file nobody ruled on.
6. **Per-platform claims are asserted on paper by X and unevenly proven by Y**; no design names the check that fails on macOS or Windows alone.
7. **Contamination**: the reified texts are mostly rulings. Rows T5, R4, S3, S5, P2, P4, E3, E6 could not discriminate at all.

## 4. Top 10 learnings

1. The standing Vault root token plus the only unseal share in an unlocked keyring, with Vault on host loopback, undoes the rest of the credential design for any same-user process (H1; `KEPT_CREDENTIALS`).
2. Three independent designs chose per-project networks; Y's spec requires an unauthenticated read-write git daemon on a shared network. The reachability probe has not been run; run it before arguing.
3. The agent-facing diagnostics the operator asked for on 2026-10-18 are still red fixtures. The blind `wait(corr, timeout)` primitive is the piece Y's change lacks, and it serves the polling ruling for LLM consumers.
4. "Count mechanisms, not secrets" (Sec L2): Y moves credentials by at least five mechanisms. Each live finding M1, M2, H3 is one mechanism's own leak path.
5. A design with no timer inventory has timers nobody chose (Evt rule 5): `memory_stall_watch` lists containers every 15 s for the life of the tray; whether that cadence was approved is not recorded where I looked.
6. Typed events with no free-text field make redaction, curation, the status line and prompt-injection resistance one mechanism. Y's hard-coded debug flags and on-disk transcripts are the free-text plane leaking past a ruling.
7. Y's own-VM, vsock and SSH-CA host-push choices beat the blind alternatives; convergence pressure should not undo them.
8. B's test — a service exists only if removing it breaks a named obligation on some platform — is the missing column in `enclave-service-catalog`.
9. The installer is fail-open on integrity for the end user the rulings protect: a missing checksum file is skipped, not refused.
10. A read-only audit must not become the leak: the black-box run printed two secrets. The audit belongs in a subcommand that reports counts and locations with three verdicts.

Process learning: the next blind run needs a clean context (Sec L15). Eight of my thirty-two area rows were unusable for independence.

## 5. Keep from each

- **Current (Y):** own Fedora guest with `VmRuntime` and vsock; Vault with per-container AppRole policies and the SSH CA host-push certificate; GitHub App device flow as the one git identity; pre-receive atomic relay in the mirror; cap-drop / no-new-privileges / no engine socket / no host mounts; name-constrained preview CA; `image-pins.yaml`; licence registers, `restricted_fetch` and `licence_consent`; cheatsheet source layer; `runtime-diagnostics-stream` ring; the shell-to-Lua ratchet; the wipe-and-sign-in path.
- **Designer A:** idle ladder; admission control with a slot formula; per-project networks with no default route; structured 403 from the egress proxy; budgets table with an enforcer per row; "tray never in a data path".
- **Designer B:** dormant/attached tray modes; `reconcile(desired, actual-from-labels)` as the one code path for launch and recovery; the removal test and cut list; release manifest with a previous-manifest rollback; `forge-init` in Rust replacing entrypoint shell.
- **Security design:** invariants I1–I14 as the audit spine; threat model; identity by per-forge socket; lifetimes and revocation table; digest-bound approval rendered from structured fields; the enumerated, visible I2 exception; the read-only audit with population and three verdicts; `unknown` licence class; docs bundle by digest.
- **Events design:** two planes; closed field kinds; hub-stamped identity; snapshot + deltas + `hub.gap`; `wait`; token budgets; timer inventory; the list of undesigned copies (journal, swap, scrollback, transcripts).
- **Drop:** `podman machine` (A, B); B's loopback TCP control port; B's single merged gateway; Sec's TUF + SLSA + SBOM stack until one consumer needs it; `podman-secrets-migration` as written; the standing root token; hard-coded debug flags.

## 6. Recommended target per area

- **Tray.** Keep Y's native trays and transport. Adopt B's two modes as the stated model, with a timer inventory and a per-platform wakeup/RSS gate once OQ-1/OQ-2 are answered. Move "what exists" to podman labels with adopt-on-start (already the direction of `hot-upgrade-live-stack`).
- **Cloud.** Keep Y's services, add a cost and removal-test column per service. Give each project its own internal network joined only to the services it needs, starting with forge + mirror. Stop the guest when idle if OQ-2 says the whole product is bound.
- **Credentials.** Keep Vault. Remove the standing root token; the tray holds a scoped token. One delivery mechanism for container secrets (tmpfs file 0400, or a socket), no long-lived credential on disk outside the keyring, narrow socket for the router, Vault off host loopback. Write the threat model and answer OQ-17/18. Treat "credential in the forge" as a counted, labelled exception pending OQ-16.
- **Supply chain.** Installer verifies or refuses. Decide prebuilt signed images versus local builds with the operator. Keep the registers; mount models read-only; route the ollama path through the register; make missing cheatsheet provenance an error for files shipped into the forge.
- **Events.** Finish `forge-diagnostics-scope` with X's `wait`, cursor, gap and token budget. Adopt the no-free-text rule for anything crossing a forge boundary. Default debug flags off; make transcripts die with the forge; rule on the Vault audit file with OQ-6.

## 7. Rubric defects found while scoring

- The n.i. rule gave X the same score as Y on eight rows, which hides X's independent additions on those rows (digest-bound approvals, `unknown` licence class). I list them in the evidence column instead of re-scoring.
- "Implemented-ness 4 = gated on all claimed platforms" could not be checked read-only; Y's 3s are judgments from specs, crates and the live Linux audit.
- T and R were written per designer but several rows (T5, R3) depend on rulings more than on either design.
- Y was not scored blind: I knew the label.
