# Gaps — judge 2: proposed packets

Not filed. Each packet: title in words, why, an exit criterion that fails on
today's tree (`e886f596c`), capability tags, suggested release, and a severity
where it is a security matter. Code is cited by symbol. "Existing row" means
the ledger already carries the work and I recommend a priority change instead
of a new packet.

Severity scale: High = one compromised forge or one same-user process reaches
another project's code or the operator's sign-ins. Medium = a second failure
is needed. Low = hygiene.

## A. New packets

### G1. Each project's forge and mirror share a network no other project is on
- **Why.** Every forge, mirror, login container, inference and router sits on
  the one `tillandsias-enclave` (`ENCLAVE_NET`). The mirror serves
  `git daemon --export-all --enable=receive-pack` with no client
  authentication and relays accepted pushes to GitHub with the operator's
  token. The only thing between project A's forge and project B's mirror is a
  random hostname on a /24. `spec:podman-idiomatic-patterns` already names a
  per-project network and `enclave_network_name()` exists with no caller.
  This closes the cross-project half of the problem without waiting for the
  SSH-CA transport (451, pending, blocked on a parked row).
- **Exit criterion (fails today).** A unit test builds run arguments for the
  mirrors and forges of two projects and asserts the two forges share no
  network name, and that neither forge's networks contain the other project's
  mirror. Today both sets are exactly `tillandsias-enclave`. Live arm: with two
  projects up, `git ls-remote git://<other project's mirror address>:9418/<repo>`
  from inside forge A fails to connect; today the configuration implies it
  succeeds (never demonstrated — run it once before the fix to record the
  pre-fix result).
- **Tags.** podman, network, security, git-mirror, rust; holds separately in
  the macOS and Windows guests.
- **Release.** v0.5. **Severity.** High.

### G2. The tray stops holding the Vault root token after bootstrap
- **Why.** `persist_healed_root_token` and the fresh-init handover write
  `vault-root-token-v1` to the keyring, and every host Vault call goes through
  `read_and_handover_root_token`. A `tray` policy exists and is not what the
  host uses. With the 1-of-1 share in the same keyring, any same-user process
  holds everything, and nothing about the product needs root after policies
  and roles are loaded. `generate-root` from the share already exists for the
  rare case that needs it.
- **Exit criterion (fails today).** After a clean start the keyring has no
  `vault-root-token-v1` item (on macOS: not in `KEPT_CREDENTIALS`), the token
  the tray holds answers `token lookup` with policy `tray` and not `root`, and
  the root token minted at init is revoked (`token lookup` on it returns 403).
  Today the item is present and the tray's token is root.
- **Tags.** vault, credentials, keyring, rust, linux, macos, windows.
- **Release.** v0.5. **Severity.** High (its ceiling depends on OQ-17; the
  change is worth making under either answer).

### G3. A forge can read its harness sign-in but cannot replace it, and says it holds one
- **Why.** `images/vault/policies/claude-forge.hcl` grants `create`, `update`
  and `read` on the install-wide `secret/data/claude/oauth` (same shape for
  the other harnesses). A prompt-injected agent in any project can overwrite
  the document every later forge restores. Separately, README ("credentials
  stay outside the forge") and `spec:podman-idiomatic-patterns` ("capabilities,
  never credentials") state something the harness path does not do.
- **Exit criterion (fails today).** With a token minted for a Claude forge, a
  write to `secret/data/claude/oauth` is refused with 403 (today it succeeds);
  rotation harvest still works because the write is made by a host-side step
  or a separate single-purpose token the agent's process cannot read. The
  README sentence and the spec sentence either carry the exception by name or
  a check fails on them. The forge's launch record carries a field saying a
  live upstream credential is present.
- **Tags.** vault, credentials, forge, policy, docs, operator-decision (OQ-16
  decides whether the credential can leave the forge entirely).
- **Release.** v0.5. **Severity.** High.

### G4. The router gets its own socket that accepts one message
- **Why.** `build_router_run_args` binds `control_socket_dir()` read-write
  into the router, which every forge talks HTTP to and which is published on
  the host. On that socket `decide_route` accepts `VmShutdownRequest`,
  `EvictProject`, `Subscribe`, `CloudRefreshRequest` and `McpFrame` as well as
  the one message the sidecar needs (`IssueWebSession`). Credential handover
  is already refused on this transport, so this is containment, not a leak.
- **Exit criterion (fails today).** The router's mount source is not
  `control_socket_dir()`; a client on the router's socket that sends
  `VmShutdownRequest`, `Subscribe` or `McpFrame` gets `Unsupported`; and the
  mount is the socket's directory read-only or the socket file itself. Today
  the same socket serves all of them and the directory is `rw`.
- **Tags.** control-wire, router, podman, security, rust.
- **Release.** v0.5. **Severity.** Medium.

### G5. The host-push lane keeps no plaintext AppRole document or unencrypted key
- **Why.** `scripts/tillandsias-host-push-cert.sh` reads
  `~/.config/tillandsias/host-push/<host>.approle.json` and an ed25519 key made
  with an empty passphrase, by stated design, to avoid a keyring call on push.
  The ruling `no-plaintext-credentials-at-rest` says to treat this as a defect.
  The certificate it mints is well constrained; the thing that mints it is
  standing and survives a Vault wipe as a dead file.
- **Exit criterion (fails today).** After provisioning, no file matching
  `*.approle.json` exists under the host-push directory and `ssh-keygen -y -P ''`
  on the lane's key fails or the key is not on disk; a push still succeeds on a
  host with an unlocked keyring; on Vault re-initialisation the old material is
  removed. Today the script exits `fail:host-push-cert:no-approle-document`
  without the file.
- **Tags.** credentials, fleet, git-mirror, keyring, linux.
- **Release.** v0.5. **Severity.** Medium. This lane is fleet tooling, not the
  end-user product; say so in the row.

### G6. One command lists every credential file the product owns and fails on a stranger
- **Why.** There is no single inventory. The audit found a 10-year
  "Tillandsias CA" private key at `~/.cache/tillandsias/ca-key.pem` that no
  code in the tree writes or deletes (it appears only in history), a
  probably-dead host-push AppRole, and nix-cache signing keys in plaintext.
  `purge_credential_fallbacks_in` covers three named files only. The
  milestone 590-z3jh asks for runtime audits per credential; this is the
  instrument those audits need.
- **Exit criterion (fails today).** A read-only subcommand walks the product's
  storage roots, classifies each key-shaped or token-shaped file against a
  declared table (name, owner, store, lifetime), asserts the population it
  scanned is non-empty, never prints a value, and exits non-zero on an
  undeclared file. Run on macuahuitl today it must name `ca-key.pem`. No such
  subcommand exists.
- **Tags.** credentials, audit, rust, lua-data, linux, macos, windows.
- **Release.** v0.5. **Severity.** Medium.

### G7. Proxy, mirror and inference run without debug logging unless asked
- **Why.** `build_proxy_run_args` sets `DEBUG_PROXY=1`, `build_git_run_args`
  sets `GIT_TRACE=1`, and the inference arguments set `OLLAMA_DEBUG=1`,
  unconditionally. The last one writes prompt content to the container log,
  which the log ruling treats as possible personal data.
- **Exit criterion (fails today).** With `debug == false` none of the three
  variables is in the built arguments; with `--debug` they are. Today a test
  asserts `DEBUG_PROXY=1` is always present, so that test must change with the
  fix.
- **Tags.** podman, logging, privacy, rust.
- **Release.** v0.5. **Severity.** Medium.

### G8. Images that sit next to credentials build from digest-pinned bases
- **Why.** `images/image-pins.yaml` holds four digests. The vault image
  (`hashicorp/vault:1.18`), the mirror (`alpine:3.20` and the Vault Agent
  stage), the proxy (`alpine:3.22`), the router (`caddy:2-alpine`) and the
  forge and inference bases (`fedora-minimal:44`) are tags, resolved on each
  user's machine at build time.
- **Exit criterion (fails today).** The pin check fails when any `FROM` in
  `images/{vault,git,proxy,router,inference,default}/Containerfile` lacks
  `@sha256:`. Today the check only validates pins that already exist.
- **Tags.** supply-chain, containers, lua, podman.
- **Release.** v0.5. **Severity.** Medium.

### G9. Language models are pulled by digest from a register, like studio weights
- **Why.** Studio weights go through `restricted_fetch` (register row, sha256,
  suffix allowlist, licence gate). `images/inference/entrypoint.sh` runs
  `ollama pull "$_model"` by tag, with no register row and no licence record,
  and the model cache is mounted read-write into the inference container.
- **Exit criterion (fails today).** The inference entrypoint refuses a model
  whose name and digest are not in a shipped register and reports
  `model_refused`; after a pull the stored manifest digest equals the register's;
  the cache mount is read-only except during a pull. Today any tag is pulled.
- **Tags.** supply-chain, models, inference, licence.
- **Release.** v0.6. **Severity.** Low to Medium.

### G10. A measured idle budget per state and platform, with a gate that has been seen red
- **Why.** The promise is "near-zero overhead" and no spec carries a number.
  One live sample: tray Pss 16.6 MB, 36 threads, about 22 context switches a
  second with one forge up. Both tray designers independently defined overhead
  by state (tray only; cloud up, no forge; one forge idle) and asked for a
  mutation control.
- **Exit criterion (fails today).** A measurement step records tray memory and
  wakeups over ten minutes in each state on each platform and writes a
  per-platform verdict against a committed number; adding a one-second timer
  to the tray makes it fail. Today there is no number and no step.
- **Tags.** tray, measurement, linux, macos, windows, operator-decision
  (OQ-1, OQ-2 supply the numbers).
- **Release.** v0.5 for the instrument, numbers when ruled.

### G11. Every periodic cadence in the product is listed with its wakeups per hour and its approval
- **Why.** The polling ruling requires approval per cadence. There is no list.
  `memory_stall_watch::INTERVAL` is 15 s and each pass lists containers (240
  passes an hour while the tray runs); `PTY_HEARTBEAT_INTERVAL` is 30 s; the
  external-logs auditor runs each 60 s by its spec (not read in code). Memory pressure has a kernel trigger
  interface, so the first of these can become an event wait.
- **Exit criterion (fails today).** A committed table names each cadence, its
  owner, wakeups per hour and the approval it rests on; a check fails when a
  periodic constant or interval call appears that the table does not name. On
  today's tree the check fails on the three above. Second arm: the memory
  stall watch makes zero wakeups in ten minutes with no container under
  pressure.
- **Tags.** tray, polling, rust, lua, linux.
- **Release.** v0.5.

### G12. A forge agent can ask one tool what is happening and when to retry
- **Why.** The lane MCP socket offers browser, preview, publish, studio,
  toolchain and image tools. An agent cannot ask for its forge's state, a
  shared service's state, or a retry time in one place; each tool invents its
  own `retry_after`. The events designer's rule — closed field kinds, no free
  text, origin stamped by the host, pull with a cursor — fits the existing
  socket and needs no new process.
- **Exit criterion (fails today).** `tools/list` on a lane socket includes a
  status tool; its result contains only enums, bounded numbers, registered
  names and the caller's own ids; it reports own-forge state, containers the
  forge started, and curated states of shared services with `retry_after_s`;
  a second forge's ids never appear. Today no such tool is listed.
- **Tags.** mcp, forge, observability, rust.
- **Release.** v0.6.

### G13. Nothing the launcher wrote about a forge is left after the forge is removed
- **Why.** `terminal_handoff::attached_session_log_path` appends the
  launcher's diverted output to `attached-sessions/<container>.log` under the
  state directory, mode 0644, and keeps it. It is launcher output, not the
  agent's transcript, but it includes tool-call side effects, and the log
  ruling says session logs end with the forge. The Vault audit log is also
  unbounded (527 MB on this host).
- **Exit criterion (fails today).** After a forge exits and is removed, no
  file for that container remains under `attached-sessions`; while it runs the
  file is 0600. The Vault audit device has a size bound. Today the file stays
  and the audit log grows without limit.
- **Tags.** logging, privacy, podman, rust, operator-decision (OQ-6 for the
  audit log).
- **Release.** v0.5. **Severity.** Low.

### G14. Shell that ships inside containers has a line floor that only falls
- **Why.** `images/` carries 107 shell files and 25,363 lines that run on
  every user's machine: `lib-common.sh` 6,032, the mirror entrypoint 980, its
  pre-receive hook 794. Total shell in the repository went from about 49k to
  210,854 lines in 90 days. The existing floors count call sites, not lines.
  Three Python files (1,117 lines) run in studio images against the
  no-Python rule.
- **Exit criterion (fails today).** A check compares `images/**/*.sh` lines to
  a committed floor and fails when the count rises; `git ls-files 'images/**/*.py'`
  is empty or each file has a dated waiver. Today there is no line floor and
  three Python files.
- **Tags.** shell-to-lua, images, lua, rust, ratchet.
- **Release.** v0.5 for the floor; the rewrites ride as carried obligations.

### G15. Modules with no consumer are wired or removed
- **Why.** In `tillandsias-logging`, the types of `aggregator`, `sampler`,
  `span_context`, `surface` and `schema_validation` (about 3k lines) have no
  user outside the crate. `enclave_network_name` has no caller.
  `control_dispatch` is marked STAGED under `allow(dead_code)` since a May
  plan. A row exists for the logging query module and for `container_profile`
  (577); this extends the same disposition.
- **Exit criterion (fails today).** A check lists each public module of
  `tillandsias-logging` and fails when one has no non-test reference outside
  the crate; today it fails on five. `control_dispatch::decide_route` is
  called by both dispatchers or the module is gone.
- **Tags.** dead-code, rust, logging, control-wire.
- **Release.** v0.6.

### G16. The guest stops when no forge has been open for a ruled time (macOS, Windows)
- **Why.** The guest starts with the tray and runs until the tray exits. A
  small tray keeping a multi-gigabyte guest warm satisfies the sentence and not
  the user. Both tray designers made "stopped means the VM is off" an
  obligation.
- **Exit criterion (fails today).** With no forge open for the ruled interval,
  the guest process is absent (macOS) or the distro is `Stopped` (Windows),
  and the next launch starts it; the timer is one wakeup per idle period.
  Today the guest never stops while the tray runs.
- **Tags.** vm, macos, windows, tray, operator-decision (OQ-2).
- **Release.** v0.6, after OQ-2.

## B. Existing rows — change priority, do not refile

| Existing row | What I found | Recommendation |
|---|---|---|
| 1068-phrh installer skips verification three ways | Confirmed in `scripts/install.sh` (three "skipping checksum verification" branches; no cosign use) | p2 → p1; it is the first thing a new user runs |
| 451 authenticated forge write transport | `pending`, blocked on a parked row; the anonymous daemon is live | Unpark the blocker or land G1 first so the exposure shrinks while 451 waits |
| 588-8mh8 cheatsheet provenance is unverified | 185 of 254 cheatsheets last verified in April or May; source layer tombstoned | Add a staleness arm: a cheatsheet older than a ruled age is labelled stale to agents |
| 1252-qyii SELinux to enforcement, and 1118-zzs4 mandatory `label=disable` | The two rows pull in opposite directions | Reconcile before either is picked up |
| 972-umik control wire unauthenticated by default | Not re-verified here | Keep p1; it bounds B3 and B4 |
| 590-z3jh credential audit milestone and children | Still `ready`; this exercise did part of it by accident | Use §3 of `comparison.md` as the starting map; G6 is its instrument |
| 578 promotion evidence is forgeable | Not re-verified | Keep; it bounds B5 |

## C. Not packets — operator questions this judgement leans on

OQ-2 (what "near-zero" binds), OQ-16 (subscription token through a gateway),
OQ-17 (same-user process in scope) and OQ-6 (anything survives a forge) change
the ceiling of G2, G3, G10, G13 and G16. None of them blocks G1, G4, G7 or G8.

## D. Things I looked for and did not find

- Whether the release binary links `tillandsias-plan`: not checked.
- Whether the 15 s memory-stall cadence had operator approval: not found.
- Whether provider keys still reach a forge by environment (590-mtgn): the
  audit saw none for a Claude login container; not checked for OpenCode.
- A live cross-project `git ls-remote`: not run by anyone.
