# Gaps — proposed packets from the blind comparison (judge 1)

Ordered by value. Nothing here was filed. Each exit criterion is written so that
today's code fails it; the evidence for "fails today" is by symbol or spec name.
Severity is given for security items (High / Medium / Low). Where an open change
already covers part of a gap it is named, so the packet extends it instead of
duplicating it.

## Immediate action (not a packet)

**Rotate what the black-box audit printed.** The audit session's transcript holds the
enclave intermediate CA private key (keyring item `ca-key:intermediate.key`, created
2026-11-04, so a restart does not regenerate it) and one git-mirror AppRole
role_id + secret_id. Regenerate the intermediate key and revoke that secret_id.
Severity High until done.

## Packets

### 1. The tray stops keeping a Vault root token — Security, High
- **Why.** Root token and the only unseal share sit in the same unlocked keyring and Vault listens on host loopback, so any process of the user reads every stored sign-in and can mint SSH certificates (blackbox H1). No blind design keeps a standing root credential.
- **Fails today.** `KEPT_CREDENTIALS` in `reset_state.rs` lists `vault-root-token-v1`; `vault_bootstrap.rs` carries `fallback_vault-root-token-v1` and passes `root_token` through the handover.
- **Exit criterion.** After a fresh init and one forge launch: (a) a keyring search for service `tillandsias` returns no item whose label starts `vault-root-token`; (b) a token self-lookup with the tray's working token returns a policy list that does not contain `root`; (c) a forge launch and a GitHub sign-in still succeed.
- **Tags.** linux, macos, windows, vault, tray. **Release.** v0.5.

### 2. A forge cannot read or push another project's mirror — Security, High
- **Why.** Spec `git-mirror-service` (req c44c1dba) requires `git daemon --export-all --enable=receive-pack` on the shared enclave; the only separation is the opaque alias from `mirror_service_hostname`, and an accepted push is relayed upstream with the operator's identity (H2). Three blind designs independently put each project on its own network.
- **Step 1 (probe, multi-outcome).** From a forge of project A: `git ls-remote` and a push against project B's mirror by alias and by address. Outcomes: both refused / read allowed / write allowed / unreachable. Record which.
- **Exit criterion.** A fixture that starts two projects and runs that probe gets "refused or unreachable" for read and write, and project A's own clone and push still work. On today's topology (one `tillandsias-enclave`, daemon as specified) the read is expected to succeed; if the probe says otherwise, close this as falsified and keep the fixture.
- **Relation.** Narrow slice of `app-networks` (1800-gjqq, v0.6) and `workload-identity-plane` (1684-tx37, v0.6); do not wait for them.
- **Tags.** linux, podman, git-mirror, network. **Release.** v0.5.

### 3. The router gets a route-registration socket, not the tray's control directory — Security, High
- **Why.** The one container every forge speaks HTTP to, also published on the host, can connect to and replace the tray control socket (H3).
- **Fails today.** The router run args bind the control directory at `/run/host/tillandsias` with `:rw`.
- **Exit criterion.** `podman inspect` of the router shows no read-write bind of a directory containing `control.sock`; a connect to the control socket from inside the router fails; a preview route can still be registered. Also assert Caddy's admin port is not listening on the enclave address.
- **Tags.** linux, macos, windows, router. **Release.** v0.5.

### 4. Forge agents can ask what happened, wait for it, and read their own logs
- **Why.** Operator request of 2026-10-18. The change `forge-diagnostics-scope` (1779-sq9g) is at 0 of 7 tasks; agents have `preview.logs` only. Add from the blind events design: a blocking `wait(corr | types, timeout)`, a cursor with `gap` on loss, a snapshot call, and a `max_tokens` budget on every read.
- **Fails today.** Three fixtures in `mcp_socket.rs` are `#[ignore = "red until 1779-sq9g is implemented"]`; `host_tools.rs` has no events, state or wait tool.
- **Exit criterion.** Those fixtures run un-ignored and pass; a new fixture starts an image ensure, calls `wait` once, and receives the completion event with zero intermediate tool calls; a read with `max_tokens=200` returns at most that estimate and a header saying how many events were not shown; a forge cannot obtain an event whose source is a sibling forge.
- **Tags.** linux first, then macos, windows; mcp, diagnostics. **Release.** v0.5.

### 5. One mode and one owner for every secret file handed to a container — Security, Medium
- **Why.** Runtime secret files are world-readable inside containers (M1). The open change `podman-secrets-migration` would move them to podman secrets, whose default file driver stores plaintext on disk — against `no-plaintext-credentials-at-rest`.
- **Fails today.** `vault_bootstrap.rs` sets `0o444` in two places and a unit test asserts `0o444`.
- **Exit criterion.** Every file the tray writes under its runtime secrets directory is mode 0400 (asserted over a non-zero count), each consuming service still starts, and inside the forge-image login container a second uid cannot read the token file. Close or rewrite `podman-secrets-migration` with the ruling cited.
- **Tags.** linux, macos, windows, vault, podman. **Release.** v0.5.

### 6. No long-lived credential on disk outside the keyring — Security, Medium
- **Why.** The host-push AppRole JSON and an unencrypted SSH key sit in `~/.config/tillandsias/host-push/`, and a 10-year root CA key with no name constraints sits in `~/.cache/tillandsias/ca-key.pem` (M2). A Vault wipe leaves dead host-push material behind.
- **Exit criterion.** A sweep of every Tillandsias-owned host directory reports the number of files scanned (non-zero) and zero files that parse as a private key or contain a `role_id`/`secret_id` pair; host push still works after a Vault wipe and re-init without manual cleanup. Today the sweep finds at least four.
- **Tags.** linux, vault, host-push, ca. **Release.** v0.5.

### 7. The installer refuses when it cannot verify — Security, Medium
- **Why.** The end user never sees the terminal; integrity must not be optional.
- **Fails today.** `scripts/install.sh` prints "skipping checksum verification" and installs when `sha256sum` is absent, when `SHA256SUMS` cannot be fetched, or when the asset is not listed. No installer verifies the Cosign bundle that `binary-signing` publishes.
- **Exit criterion.** A fixture serving a release with no `SHA256SUMS`, and one with a wrong digest, each make the installer exit non-zero with one plain sentence and leave no binary; repeat for macOS and Windows installers. Second slice: signature verification with the pinned identity.
- **Tags.** linux, macos, windows, installer, release. **Release.** v0.5.

### 8. "Near-zero overhead" becomes a budget with a gate, per platform
- **Why.** No spec states a number (OQ-1, OQ-2). Resident loops exist that nobody listed: `memory_stall_watch::INTERVAL` (15 s, lists containers each pass, spawned from the tray), the `lane-freshness` 60 s loop, `PTY_HEARTBEAT_INTERVAL` (30 s).
- **Slices.** (a) A timer inventory: every periodic wakeup in the tray and guest agent, its cadence, wakeups per hour, what it earns, and whether it runs with zero containers — put to the operator under the polling-cadence ruling. (b) A measurement fixture: tray idle for 10 minutes with nothing launched, reporting wakeups per minute and RSS. (c) The gate, once the operator gives the number.
- **Exit criterion.** A check fails when the tray source contains a periodic loop not present in the inventory; the fixture fails above the budget. Today there is no inventory and no budget, so both fail.
- **Tags.** linux, macos, windows, tray, operator-decision. **Release.** v0.5 for (a) and (b); (c) after OQ-2.

### 9. Diagnostics that outlive or over-share: debug flags, transcripts, the Vault audit file — Security, Medium (privacy)
- **Why.** Against `forge-logs-die-with-the-forge`: `terminal_handoff` writes agent terminal transcripts to `attached-sessions/*.log` (0644); `DEBUG_PROXY=1`, `GIT_TRACE=1`, `OLLAMA_DEBUG=1` are hard-coded in the service run args (and one is asserted by a test), so prompts and decrypted URLs reach container logs; the Vault audit file is 527 MB, unrotated, and survives a store wipe.
- **Exit criterion.** Service run args contain none of the three flags unless the tray was started with `--debug`; after a forge closes no file under the state directory holds its transcript (checked over a counted set); the state directory is 0700. The audit-file retention is an operator question (OQ-6) and is listed, not decided.
- **Tags.** linux, macos, windows, logging, privacy. **Release.** v0.5.

### 10. A read-only security audit subcommand that cannot leak
- **Why.** The black-box audit found real defects and also printed two secrets. The blind checklist's rules — assert the population, three verdicts (PASS / FAIL / NOT RUN), report location and count, never the matched bytes — should be a tool.
- **Exit criterion.** One subcommand, run against a live system seeded with a canary secret in a runtime file, reports the canary's path, never its bytes (the output is grepped for the canary), prints the number of sinks scanned per check, and returns NOT RUN rather than PASS for a container it cannot inspect. Rows 1, 3, 5, 6, 9 above each appear as a check. Today no such command exists.
- **Tags.** linux first; rust, lua-data. **Release.** v0.6.

### 11. A written threat model with one probe per boundary — Security, Medium
- **Why.** No spec, cheatsheet or methodology file states actors, assets and boundaries; OQ-17 (same-user attacker) and OQ-18 (disk encryption) are open, and H1 is exactly the undecided case.
- **Exit criterion.** A spec exists that names the actors and boundaries from the blind `threat-model.md`, records the operator's answers to OQ-17/18, and binds each boundary to a named check; a spec lint fails when a boundary has no check. Today the lint would find no document.
- **Tags.** spec, operator-decision. **Release.** v0.5 (document), checks follow.

### 12. The guest stops when nothing needs it (macOS, Windows)
- **Why.** The VM runs for the tray's whole lifetime (`vm-provisioning-lifecycle`); on a floor host that is the overhead the promise denies. Depends on OQ-2.
- **Exit criterion.** With no forge and no appliance for the approved interval, the VM process (macOS) or the distro (Windows) is absent, and the next launch brings it back; measured per platform. Today it never stops while the tray runs.
- **Tags.** macos, windows, vm, operator-decision. **Release.** v0.6.

### 13. Every service states what it earns and what it costs
- **Why.** Blind designer B's test: a service exists only if removing it breaks a named obligation on some platform. `enclave-service-catalog` has no such column; nix-cache, the router sidecar and inference start with the session.
- **Exit criterion.** The catalog carries, per service, the obligation it pays for, when it starts, and a measured idle RSS; a check fails when a running `tillandsias-*` container has no catalog row or a row has no obligation. Today both conditions fail.
- **Tags.** linux, spec, metrics. **Release.** v0.5.

### 14. Containers run with SELinux confinement — Security, Medium
- **Why.** With keep-id the MCS label is the main barrier after an escape; 55 sites pass `label=disable` (M3).
- **Exit criterion.** Research first: which mounts force the opt-out. Then: the forge container's process label is a confined container type with its own categories, and the forge still starts. Today every container is unconfined.
- **Tags.** linux (Fedora), podman, research. **Release.** v0.6.

### 15. Model weights are read-only to the engine and carry their licence — Security, Low
- **Why.** The inference container mounts the model cache read-write, so one compromised engine can swap weights for every project; no licence text sits beside any weight (L5); it is not shown that the ollama path consults the licence register.
- **Exit criterion.** Outside an explicit pull the model mount is read-only in `podman inspect`; each model directory holds the licence text named by its register row with a matching hash; a pull of a model absent from the register is refused.
- **Tags.** linux, macos, windows, inference, licence. **Release.** v0.6.

### 16. One storage root on the live host
- **Why.** `host-state-lifecycle` and the storage ruling say one root; the live host uses five, with the Vault store under `~/.cache` where cleaners and backup exclusions apply (L3).
- **Exit criterion.** After a fresh install and one forge session, every path the tray created is under `~/.tillandsias` or the runtime directory (asserted from a recorded list of created paths). Today the Vault store, CA key, logs and host-push material are elsewhere.
- **Tags.** linux, then macos, windows; storage. **Release.** v0.6.

### 17. Decision: prebuilt signed images by digest, or local builds
- **Why.** All three blind designs pull; the current product builds every image on the user's machine, which is slow on floor hosts and the reason flaky installs needed their own direction. Compatible with one intentional release build a day. Operator decision; no code until ruled.
- **Exit criterion for the decision packet.** A measured comparison on one floor host: time from install to first usable forge by local build versus pull, with download size, put to the operator as one plain ask.
- **Tags.** operator-decision, release, images. **Release.** v0.6.

### 18. Credentials inside a forge are counted and labelled
- **Why.** Harness credential documents are restored into the forge (`tillandsias-vault`). Whether a relay may attach them instead is OQ-16. Until then the exception should be visible, as the blind security design requires for its I2 exception.
- **Exit criterion.** The tray can list, per running forge, which provider credential documents were restored into it; the audit (packet 10) reports that count. Today nothing enumerates them.
- **Tags.** vault, tray, operator-decision. **Release.** v0.6.

### 19. Shipped cheatsheets without provenance are an error
- **Why.** 29 of 256 files under `cheatsheets/` have no `## Provenance` heading and an unfetched source is only a warning in `check-cheatsheet-sources`.
- **Exit criterion.** The check exits non-zero for any cheatsheet staged into the forge image that lacks provenance, over a counted population, with an explicit exemption list for index and template files. Today it exits zero.
- **Tags.** cheatsheets, policy. **Release.** v0.5.

### 20. Blind exercises start from a clean context
- **Why.** Every designer saw CLAUDE.md, the memory index and the skill list; eight of thirty-two rubric rows could not measure independence.
- **Exit criterion.** The launcher for a blind designer produces a session whose first-turn context contains none of those three, shown by the designer's own first message listing what it was given.
- **Tags.** process. **Release.** next exercise.
