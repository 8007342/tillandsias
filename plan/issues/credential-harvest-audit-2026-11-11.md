# Credential harvest audit (sighted), 2026-11-11

Order 2080. Read at trunk `e1f8d7f01` (linux-next). Sighted counterpart of the
blind black-box audit run the same day against the live v56.11.10.1 install.
Read-only: nothing was rotated, wiped or signed in. No secret value appears
here; where one was seen on a live host only its location is named.

Method: code read (symbols named below), the folded plan ledger for existing
coverage, and five operator rulings (no plaintext credentials at rest; a
broken vault is wiped, not recovered; agents never start a sign-in; never
weaken a fail-closed credential gate for a test; the 2026-10-25/27 approval
rulings). Reads went through the forge-plan MCP first; files were the
fallback for code (not exposed) and for the filing rule (`methodology_ask`
answered unsupported; `methodology/distributed-work.yaml`
`order_id_allocation` and `plan/index.d/README.md` were read instead).

Regime of every statement: Linux native rootless podman unless a row says
macOS or Windows. macOS and Windows rows are from code only, not run.

## 1. Verdict in one paragraph

The stores are in better shape than the black-box audit suggests (keys on
tmpfs, keyring-sealed CA keys, no podman file-driver secrets on the product
path, a fail-closed git credential helper, Cloudflare tokens that never enter
a container). The harvesting is what is messy: there are **fourteen distinct
paths** by which a credential is minted, read or moved, written in four
languages, and seven of them duplicate another. The three structural defects
are (a) every host-side Vault operation authenticates as **root**, from about
twenty call sites, while the `tray-policy` that was written for the purpose
is bound to nothing; (b) **forge lanes hold the complete provider sign-in
document**, refresh token included, and may overwrite the stored copy; (c)
the **router container can speak the tray's whole unix control wire**.

## 2. Findings by severity

Counts: High 6, Medium 12, Low 5, Info 3. "BB" is the black-box finding id.
"Row" names the packet that carries the fix: an existing one where the
ledger already has it, a new 2080 packet otherwise.

### High

| id | finding | evidence (symbol) | row |
|---|---|---|---|
| H1 (BB H1) | CONFIRMED. The Vault root token and the single unseal share rest in the same OS keyring service, with the enclave and preview CA keys, and Vault is published on host loopback. | `read_and_handover_root_token` stores both with `keychain_set_blocking`; `ensure_unseal_key` reads the share; `vault_host_publish_arg`; `images/vault/entrypoint.sh` runs `operator init` with one share, threshold one; `ca_key_store::seal` | 2080-yvby, 2080-dy3a; decision D1 |
| H1b | NEW. Root is the only host identity. Every host Vault read, write, mint and revoke takes the root token: about twenty callers of `read_and_handover_root_token`, plus `vault_exec_output`, which feeds root to the in-container CLI on stdin. `Policy::Tray` (`images/vault/policies/tray.hcl`) is loaded and given an AppRole by `provision_approle_roles`, and nothing ever logs in with it. `heal_stale_root_token` can mint a new root from the share alone, so removing the token without protecting the share changes nothing. | named symbols | 2080-yvby, 2080-dy3a |
| H2 (BB H2) | CONFIRMED and already known. `images/git/entrypoint.sh` starts `git daemon --export-all --enable=receive-pack` on every interface of the shared enclave network; the comment above it says so. The authenticated ssh lane exists behind `mirror_ssh_push_lane_enabled`. | `build_git_run_args`, the entrypoint's daemon block | existing 1685-kwmr, 451, 749-y8xx, 722-uern. Not refiled. |
| H3 (BB H3) | CONFIRMED, and wider than "a socket directory". `build_router_run_args` binds `control_socket_dir()` read-write. On that socket `control_dispatch::decide_route` handles, for any peer, `VmShutdownRequest`, `CloudRefreshRequest` (private repository names, fetched with the operator's GitHub sign-in), `IssueWebSession` and `EvictProject` (web-session issue and eviction for every project), `Subscribe` and `McpFrame`. No peer check. The vault handover and PTY families are refused on this transport, so no credential is read directly. 2007-rtky already narrowed the bind from the whole runtime directory. | named symbols | 2080-jmve |
| H4 | NEW. Forge lanes hold the whole provider sign-in and can replace it. The four `*-forge.hcl` policies grant `create`, `update` and `read` on `secret/<provider>/oauth`. `provider-oauth-vault.sh` and `codex-oauth-vault.sh` restore the complete credential document (refresh token included) into the forge home and copy changes back. The lane's Vault token is a file the agent can read. Roles are one per harness, not per project or forge instance. An injected agent can therefore send a long-lived refresh token out through its permitted egress, or overwrite the stored sign-in with another account's, which every later forge of that harness then restores. | policy files; the forge launch's `mint_approle_secret_lease` call with role `<mode>-forge`; `restore_auth` / `harvest` in the two scripts | 2080-cdvm, 2080-7euu; decision D2. Related 435, 590-z3jh |
| H5 | NEW, macOS. The host tray writes the Vault root token and the unseal share to the Keychain as `security add-generic-password ... -w <value>`: both are on a process argv, which macOS shows to every local user. | `write_credential_string_in` in the macOS tray's `installation_uuid` module | 2080-u6nm |

### Medium

| id | finding | evidence (symbol) | row |
|---|---|---|---|
| M1 (BB M1) | CONFIRMED, by design. `write_runtime_secret` and `write_unseal_key_file` create 0400 and then chmod to 0444, relying on the 0700 parent. Inside a container the parent is not there, so every uid reads the file. | named symbols | 2080-fqvh |
| M2 (BB M2) | CONFIRMED in part. `mint_host_approle_document` writes role id and secret id to a 0600 plain file (order 1313-prin chose this to keep the keyring off the push path; that predates nothing in the 2026-10-19 ruling but contradicts it). The secret id is reusable for 48 h (`create_approle_agent_role`), so the file the black box saw from 2026-10-02 is expired, not standing. It is never registered for revocation and never deleted. `scripts/tillandsias-host-push-cert.sh` then puts the secret id and the client token on `curl` argv, needs jq, and creates the ssh key with an empty passphrase. | named symbols | 2080-swqp; decision D3 |
| M2b (BB M2) | REFUTED as stated, real as a smaller defect. `~/.cache/tillandsias/ca-key.pem` is not the root of the enclave chain. It is the developer build proxy's CA, written by `build.sh` `ensure_dev_cache` with `-nodes` and ten years' validity. The enclave CA is the 365-day certificate from `ensure_ca_bundle`, whose key lives on tmpfs and in the keyring (`ca_key_store`). This also identifies the writer the macOS storage finding ("Plaintext private keys sit at rest on the macOS host") could not. | named symbols | 2080-m3kw |
| M3 (BB M3) | CONFIRMED. `MANDATORY_HARDENING_FLAGS` includes `--security-opt=label=disable`; Vault alone has a conditional label (`vault_selinux_label_opt`). | named symbols | existing 1693-9qfb, 1694-j2sk. Not refiled. |
| M4 (BB M4) | CONFIRMED and intended by ruling; the defect is that it is silent. `wipe_unopenable_store` runs when `unseal_failure_is_key_rejection` holds, and reports with one `eprintln!` of `SIGN_IN_AGAIN_LINE`. No tray event, no cause recorded. Why the share mismatched on 2026-11-11 cannot be answered from code. | named symbols | 2080-i4ga; decision D6 |
| M5 (BB M5) | CONFIRMED. `DEBUG_PROXY=1` in `build_proxy_run_args`, `GIT_TRACE=1` in `build_git_run_args`, `OLLAMA_DEBUG=1` in `build_inference_run_args`, all unconditional. | named symbols | 2080-363e |
| M6 (BB M6) | CONFIRMED from configuration (`ENCLAVE_ONLY_NET` is shared by every lane and service). | | existing 1684-tx37, 1688-ideu, 1689-echb, 1690-iqh5, 1691-96gk. Not refiled. |
| M7 | NEW. A provider API key in Vault reaches the forge as a `podman run --env` value: `build_forge_agent_run_args_with_vault` calls `read_provider_api_key` and `spec.env(p.env_var(), &key)`, which puts the key in podman's argv, in `podman inspect` and in the container environment. The black box saw no key in any environment only because none was stored: `write_provider_api_key` has no production caller. A reader with no writer. | named symbols | 2080-cbuq. Related 590-mtgn |
| M8 | NEW. Developer and diagnostic scripts break the at-rest ruling by name: `scripts/orchestrate-enclave.sh` and `scripts/diagnose-proxy.sh` mint the CA key with `-nodes` and run `podman secret create --driver=file`; `scripts/run-forge-project.sh` mints with `-nodes`; `scripts/check-enclave-service-health.sh` re-creates the podman secret as a repair. Three more copies of the CA mint beside `ensure_ca_bundle`. | named scripts | 2080-naqg |
| M9 | NEW. `images/vault/vault.hcl` sets `disable_mlock = true` while the container is granted IPC_LOCK, and swap is mandatory by ruling. Vault's unsealed keyring and every token can be written to swap in the clear. | `vault.hcl`; `launch_vault_container` | 2080-v2z7; decision D7 |
| M10 | NEW. Only Cloudflare can be signed out (`cloudflare_login::logout`, with `cloudflare_oauth::revoke`). GitHub and the four model providers have no sign-out and no upstream revocation. After a wipe, the lost GitHub refresh token stays valid upstream for its full life. | absence: the flag list in `main.rs` has `--cloudflare-logout` and no other logout | 2080-57jp; decision D5 |
| M11 | NEW, macOS and Windows. The root token and share cross the host-guest control wire (`DeliverCredentials`, `GetVaultHandover`), whose encrypted form is opt-in; inside the guest, `guest_credentials` answers `get` with both to any process of the guest user. | `decide_route` vsock arms; `guest_credentials::SOCKET_PATH` | existing 972-umik, 141, 145. Not refiled. |

### Low

| id | finding | row |
|---|---|---|
| L1 (BB L4) | CONFIRMED. `lane_events` chmods its socket to 0666; `launch_vault_container` mounts `/run/vault-handover` as a 0777 tmpfs. | 2080-v5ns |
| L2 | NEW. A second GitHub read path: `remote_projects` mints a `git-mirror` lease for a forge-image container and exports the token as `GH_TOKEN` there (`CREDENTIAL_VERDICT_SCRIPT`). The role is the mirror's own, so two different workloads share one identity. | 2080-74wk |
| L3 | NEW. Approval trust root is a user-writable file: `licence_consent::Verifier` trusts `allowed_signers` in the state directory, and `approval::request` takes a caller-named key and runs the polkit check in its own process. A same-uid process that appends its own key needs no check. | existing 1880-9wpd, 1890-dv7j, 1958-22yh; decision D1 |
| L4 | NEW. In-process revocation only: `revoke_pending_container_tokens` drains two in-memory registries at graceful shutdown. A crash leaves tokens to their TTL (1 h, 24 h max) and secret ids to 48 h. Accepted by the code's own comments; listed so the inventory is complete. | none |
| L5 (BB L2, L3, M2) | The Vault audit log has no size bound, and the store and audit log live under the cache directory (`vault_store_root_from`). The nix-cache signing and TLS keys are plain 0600 files under the state directory (`build_nix_cache_run_args`). | OQ-6 held; none filed |

### Info

- I1. Good pattern to copy: Cloudflare. Tokens are obtained by the tray
  process (`cloudflare_login`), stored by `store_cloudflare_token_bundle`
  (refresh record first), rotated by `spawn_cloudflare_token_rotation_scheduler`
  and used only host-side behind MCP tools (`cloudflare_mcp`,
  `cloudflare_worker_deploy`). No policy lets a container read
  `secret/cloudflare/*`.
- I2. `git-credential-tillandsias.sh` validates the host before answering and
  fails closed (1118-bscs); `github-login.hcl` can write but not read the
  refresh record.
- I3. `core::secrets::read_github_token` shells out to `gh auth token` on the
  host and is unreachable (existing 1139-imd4).

## 3. Inventory

Lifetimes are from constants; "rest" is where the credential lies when
nothing is running.

| credential | minted by | at rest | delivered | readable by | life, rotation, revocation |
|---|---|---|---|---|---|
| Vault unseal share (1 of 1) | Vault `operator init` in `images/vault/entrypoint.sh` | OS keyring `vault-shamir-share-v1` (Keychain, Credential Manager on the other hosts); encrypted by the OS | `write_unseal_key_file` to a tmpfs file per launch, scrubbed by `scrub_unseal_key_file`; to a guest by `DeliverCredentials` | any process of the host user; the vault container | life of the store; never rotated; replaced only by wipe |
| Vault root token | same `operator init`; re-minted by `heal_stale_root_token` | OS keyring `vault-root-token-v1` | `ROOT_TOKEN_MEMO` in the tray; stdin of `vault_exec_command` | any process of the host user | no TTL; never rotated or revoked |
| AppRole client token per container (`*-login`, `*-forge`, `git-mirror`) | `mint_approle_token_for_container` (root) | none (tmpfs) | `write_runtime_secret`, mode 0444, bound at `/run/secrets` | every uid in that container, including the agent | `APPROLE_TOKEN_TTL_SECS` 1 h, max 24 h; revoked at graceful shutdown |
| AppRole login pair for the mirror agent and the mirror signer | `mint_approle_auto_auth_for_container` (root) | none (tmpfs) | runtime secret; Vault Agent sinks under `/tmp` in the mirror | mirror container | secret id 48 h, reusable; destroyed by accessor when the owning container is gone |
| Host-push AppRole pair | `mint_host_approle_document` (root) | PLAINTEXT 0600 under the config directory | read by `tillandsias-host-push-cert.sh`, sent on curl argv | host user | 48 h; never revoked, never deleted |
| Host-push ssh key and certificate | the same script; certificate from `ssh-client-signer` | key unencrypted 0600; certificate public | ssh to the mirror's loopback sshd | host user | certificate 30 min, force-command, source-address |
| Forge lane ssh key | per-lane sidecar (`build_ssh_lane_sidecar_run_args`) | none | ssh-agent socket in a volume | the lane's forge, through the agent only | certificate 30 min, max 1 h |
| GitHub user token and refresh token | device flow of the shared GitHub App, run inside the login container (`run_github_device_login`); `--with-token` seed on stdin | Vault `secret/github/token`, `secret/github/refresh` | mirror: Vault Agent plus `git-credential-tillandsias.sh`; `remote_projects`: `GH_TOKEN` in a container; tray: read as root for rotation | mirror container; the `remote_projects` container; host user through root | access token about 8 h, refreshed by `spawn_github_token_rotation_scheduler` inside `GITHUB_ROTATION_WINDOW_SECS`; refresh about 6 months with a 14-day warning; no sign-out |
| Claude, Codex, Copilot, Antigravity sign-in documents | the provider's own CLI in a login container (`run_provider_login`), copied to Vault by `provider-oauth-vault.sh` or `codex-oauth-vault.sh` | Vault `secret/<provider>/oauth` | restored into the forge home (Copilot: `/dev/shm`) by the same scripts; changes copied back | the agent in every forge of that harness, read and write | provider-defined; rotated by the CLI itself and copied back; no sign-out |
| Claude approvals document | `claude-approvals-vault.sh` | Vault `secret/claude/approvals` | restored into the forge | Claude forges | none |
| Provider API keys (Anthropic, OpenAI, Gemini) | no production writer | Vault `secret/<provider>/api-key` | `--env` on the forge's podman argv; OpenCode reads the Gemini key with its lane token (`prepare_opencode_vault_auth`) | podman argv readers; the forge | none |
| OpenCode | no sign-in of its own; the Gemini key above, or local inference | | | | paused upstream by operator direction 2026-11-01 |
| Cloudflare access and refresh tokens | `cloudflare_login` (authorization code with PKCE; loopback, QR relay or paste) | Vault `secret/cloudflare/token`, `secret/cloudflare/refresh` | never leaves the tray process | host user through root | rotated by scheduler inside `CLOUDFLARE_ROTATION_WINDOW_SECS`; `logout` revokes upstream and deletes |
| Enclave CA key ("intermediate", the proxy's signing CA) | `ensure_ca_bundle` (openssl) | keyring `ca-key:intermediate.key`, sealed to its certificate; elsewhere PKCS#8-encrypted with a keyring passphrase (`ca_key_store::at_rest`) | tmpfs `keys/`; to the proxy as runtime secret `tillandsias-ca-key`, 0444 | host user; proxy container | `CA_VALIDITY_DAYS` 365; re-minted when unusable; previous CA trusted for one generation |
| Vault TLS leaf key | `ensure_vault_tls_leaf` | none (tmpfs only) | runtime secret, 0444 | vault container | re-minted after reboot |
| Preview CA key (localhost only) | `preview_ca` | keyring `ca-key:preview-ca.key` | tmpfs; only leaves reach the router | host user | name-constrained |
| Developer build proxy CA key | `build.sh` `ensure_dev_cache` | PLAINTEXT 0600 in the cache directory | squid build proxy | host user | 10 years; never rotated |
| ssh client and host signer CAs | Vault `configure_ssh_ca_generate` | inside Vault | sign endpoints, one policy per mirror (`reject_sign_wildcard`) | Vault | life of the store |
| Approval and licence signing key | not minted on Linux yet (1880-9wpd); Secure Enclave on macOS | caller-named key file; `allowed_signers` 0600 in the state directory | `ssh-keygen -Y sign` in `approval::request` | host user | approvals last `LIFETIME_MINUTES` 10; nonce single-use |
| Web-session one-time codes | tray, `IssueWebSession` | none | control socket to the router sidecar | router container | per session |
| nix-cache signing and TLS keys | first use | plain 0600 in the state directory | bind mounts, read-only | nix-cache container | none |

## 4. The fourteen harvest paths, and which overlap

| # | path | language | overlaps |
|---|---|---|---|
| A | tray to Vault over HTTPS with the root token (`vault_client`) | Rust | B |
| B | tray to Vault through `podman exec` and a stdin shim (`vault_exec_output`, `vault_kv_get_via_exec`) | Rust and sh | A |
| C | login container writes with a `*-login` token (`vault-cli.sh write-stdin`) | sh | D |
| D | forge restores and copies back with a `*-forge` token | bash | C; three scripts (`codex-oauth-vault.sh`, `provider-oauth-vault.sh`, `claude-approvals-vault.sh`) do one job |
| E | API key as podman `--env` | Rust | D for the same providers |
| F | mirror Vault Agent plus credential helper | sh, HCL | G |
| G | `remote_projects` container with the mirror's role and `GH_TOKEN` | Rust and sh | F |
| H | host-push AppRole file plus curl | bash, jq | F (a second route to the mirror's signer) |
| I | host keychain to guest over the control wire, then `guest_credentials` socket | Rust | |
| J | `ca_key_store` (keyring, tmpfs, encrypted at rest) | Rust | K |
| K | CA mint in `build.sh` and three scripts | bash | J |
| L | `core::secrets::read_github_token` (`gh auth token` on the host) | Rust | F; dead |
| M | Cloudflare in-process broker behind MCP tools | Rust | none: the target shape |
| N | approval signing with a caller-named key | Rust | |

Also duplicated: two `ProviderId` enums (one in `vault_bootstrap`, one in
`main.rs`), and two diverged copies of `vault-cli.sh` (forge image and git
image).

## 5. Consolidation onto one broker path

Target: the tray process is the only principal that talks to Vault with more
than a single-purpose token, and it does so through one module. A container
gets a capability over the per-lane socket it already has
(`/run/host/tillandsias-mcp/mcp.sock`), or one single-purpose token; never a
token that can write a credential, and never a credential on argv. That is
path M generalised. It is compatible with each ruling: nothing new rests on
disk (no plaintext at rest), nothing is salvaged (wipe stays the answer to an
unopenable store), every sign-in still starts in the tray, and no gate gains
a test seam.

Each stage lands alone and leaves the product working.

0. **Census.** One read-only subcommand lists every Vault path, policy, role
   and runtime secret with its declared reader, and is red on an undeclared
   one. This turns section 3 into a guard and gives pending 246a its
   inventory in executable form. (2080-xz8m)
1. **One host seam.** Every host Vault call goes through one module; path B
   folds into path A; path E and path L are deleted. (2080-dy3a, 2080-cbuq)
2. **The tray stops being root.** The tray logs in with the role already
   provisioned for it; the root token is revoked after bootstrap and is not
   kept, and the share is not kept beside a token that can use it. Required
   by the operator's answer to D1.
   (2080-yvby)
3. **Forges stop writing credentials.** A broker verb on the lane socket takes
   a rotated sign-in from a forge, checks it is the same account for that
   lane's harness, and stores it; the `*-forge` policies become read-only.
   (2080-cdvm, then 2080-7euu)
4. **One helper in the images.** One Rust or Lua helper replaces the three
   harvest scripts and both `vault-cli.sh` copies. (2080-94h8; counts against
   the shell-to-lua backlog)
5. **One GitHub reader.** The repository listing and the credential verdict
   move into the tray process, so the mirror is the only container that reads
   the GitHub token. Host push asks the tray to sign its certificate: no
   AppRole file, no bash, no jq. (2080-74wk, 2080-swqp)
6. **One delivery function.** Runtime secrets are owner-only; the router gets
   its own narrow socket. (2080-fqvh, 2080-jmve, 2080-v5ns)
7. **Sign-out and honest wipe.** A sign-out verb for every provider; the wipe
   is a tray event with a cause class. (2080-57jp, 2080-i4ga)
8. **One CA mint.** The script copies go; the developer proxy CA becomes
   per-session. (2080-naqg, 2080-m3kw)

Not in this order because the ledger already has it: authenticated mirror
transport (451, 1685-kwmr), SELinux confinement (1693-9qfb), per-project
network and listener authentication (1684-tx37 family), encrypted control
wire (972-umik).

## 6. Decisions needed from the operator

- D1. Is another process running as the same desktop user inside the threat
  model on Linux? If yes, the share needs an OS-verified release (the
  approval key) and stage 2 is required. If no, H1 is an accepted residual
  and stage 2 is hygiene.
  ANSWERED 2026-11-11 (relayed by the coordinator): a same-user host process
  is a minor threat (accidental misuse, not hostile software), but containers
  are protected as if hostile software were on the host, within reasonable
  limits, and the stronger option is preferred where its cost is reasonable.
  Stage 2 is required hardening. 2080-yvby moved from pending to ready.
- D2. Until a provider gateway exists, may a forge keep a read-only copy of
  the complete sign-in document, or must refresh tokens stay on the host even
  if that breaks a provider CLI's own refresh?
- D3. May host push depend on a running tray (the tray signs the certificate
  on request), replacing the plain AppRole file?
- D4. The black-box session printed the enclave CA key and one mirror AppRole
  pair into its own transcript. Re-minting the CA and letting that secret id
  expire is the operator's call; this audit touched neither.
  DONE 2026-11-11 by the operator: the intermediate CA was re-minted, the
  vault was wiped by a guest reset (every AppRole minted again), and the
  developer proxy `ca-key.pem` was deleted from the cache directory. 2080-m3kw
  stands, because `ensure_dev_cache` writes that file again.
- D5. A device-flow client cannot revoke a GitHub App user token (revocation
  needs the client secret). Is "delete locally and show the GitHub settings
  page" acceptable as GitHub sign-out?
- D6. May a wipe leave one persisted, non-secret cause record (the open
  audit-persistence question), or tray event only?
- D7. Turning mlock on makes Vault's memory unswappable. Acceptable on
  floor-tier hosts?

## 7. What was not verified

- Nothing was run against a live Vault, forge or mirror. Reachability inside
  the enclave is still unmeasured (the black-box scope note stands).
- macOS and Windows rows were read, not executed. H5 was not observed in a
  process listing.
- The cause of the 2026-11-11 share mismatch.
- Whether any provider CLI tolerates an access-token-only credential file
  (decides D2's cost).
- Studios, image generation and the audio studio were read for credential
  use and none was found; their launch arguments were not audited beyond the
  SELinux flag.
