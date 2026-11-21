# Black-box security audit — live Tillandsias v56.11.10.1 (Fedora, rootless podman)

Date: 2026-11-11, ~18:15–18:30Z. Blind (no source/docs). Read-only. All secret values redacted.
Counts: High 3, Medium 6, Low 6, Info 3. Unverified items are marked.

IMPORTANT SCOPE NOTE: the active reachability probe from inside a forge-image container
(port sweep, anonymous git access, direct-egress test, Caddy admin) was NOT run. Everything
about "what a forge can reach" below is inferred from `podman inspect` / network config, not
demonstrated. See method.md.

AUDITOR DISCLOSURE (redaction slips in my own tool output, not in these files):
1. `head -1` on `/run/user/1000/tillandsias/secrets/tillandsias-vault-approle-git-mirror-agent-visual-chess-38310-…`
   printed a full AppRole role_id + secret_id (single-line JSON).
2. `secret-tool search --all service tillandsias` printed the full PEM of keyring entry
   `ca-key:intermediate.key` (my filter only dropped the first line).
Both values exist in the audit session transcript. Recommend: rotate the enclave intermediate CA
key (restart regenerates the cert; confirm the KEY is regenerated too, the keyring entry was
created 2026-11-04), and let the visual-chess mirror AppRole secret_id expire/revoke it.

---

## HIGH

### H1. Vault root token + the only unseal share + CA keys are retrievable by any process of the user, with no prompt
Evidence:
```
$ secret-tool search --all service tillandsias | grep -E '^(label|attribute.username)'
label = vault-root-token-v1@tillandsias:default      (modified 2026-11-11 18:16:39)
label = vault-shamir-share-v1@tillandsias:default
label = ca-key:intermediate.key@tillandsias:default
label = ca-key:preview-ca.key@tillandsias:default
label = installation-uuid-v1@tillandsias:default
$ curl -sk https://127.0.0.1:8201/v1/sys/seal-status
{"type":"shamir","initialized":true,"sealed":false,"t":1,"n":1,...}
$ ss -ltn → 127.0.0.1:8201 (rootlessport → vault:8200)
```
The secret body was returned without any unlock/consent prompt (see disclosure above).
Impact: any same-uid process (editor plugin, npm postinstall, bare-metal agent, browser exploit)
gets the root token and a reachable Vault endpoint = every stored GitHub/Claude/Codex/Cloudflare
credential, plus the ability to mint SSH certs from `ssh-client-signer`. Shamir 1-of-1 with share
and root token in the same store gives no separation.
Fix: do not persist a root token (revoke after bootstrap; tray uses a scoped periodic token from
its own AppRole/policy); bind keyring items to an app-specific collection that requires unlock,
or gate reads through the OS-biometric approval path the tray already has
(`approvals/allowed_signers`); consider not publishing Vault on host loopback (use the control
socket / `podman exec` path) or require mTLS client certs on the host listener.

### H2. Per-project git mirror is an unauthenticated read+write git daemon on the shared enclave network (reachability UNVERIFIED)
Evidence:
```
$ podman top tillandsias-git-visual-chess user,pid,args
git 61 git daemon --reuseaddr --export-all --enable=receive-pack --base-path=/srv/git --listen=0.0.0.0 --port=9418 --verbose
$ podman inspect … → --network tillandsias-enclave --network-alias git-qf6p8i8b5larsti35v10  ip=10.0.42.11
$ podman network inspect tillandsias-enclave → internal=true subnets=10.0.42.0/24 opts=map[]
```
The same container holds a Vault AppRole (`VAULT_ROLE=git-mirror-agent`, token sink
`/tmp/tillandsias-vault-token`) and `git-push.log` shows it relays accepted pushes upstream.
The only separation between projects is a random hostname alias; the address is one of 254.
All forges, login containers, inference, router share this one bridge.
Impact (if reachable, which the config implies): a forge for project A can clone and push to
project B's mirror; accepted pushes are relayed to GitHub with the operator's identity. A
pre-receive policy exists (branch rules seen in `git-push.log`) but that is branch discipline,
not caller authentication.
Fix: one network per project (forge + its mirror), or authenticate the transport (ssh with the
existing Vault SSH CA — the cert in host-push already carries `source-address` + `force-command`),
and drop `--export-all`. Verify with a cross-project `git ls-remote` from a forge.

### H3. Router container is handed the tray control-socket directory read-write
Evidence:
```
$ podman inspect tillandsias-router  (mounts)
bind /run/user/1000/tillandsias/control -> /run/host/tillandsias rw=true
bind /run/user/1000/tillandsias/router/dynamic.Caddyfile -> /run/router/dynamic.Caddyfile rw=true
$ ls -la /run/user/1000/tillandsias/control → srw------- control.sock (tray pid 24402)
ports: 127.0.0.1:8080->8080, exposed 80,443,2019(Caddy admin),9090 on enclave ip 10.0.42.10
```
Caddy runs as container uid 1000 = host uid (keep-id), so it can connect to the 0600 socket.
Impact: the router is the one service every forge talks HTTP to and it is also published on the
host. A Caddy bug, a reachable admin API (2019, UNVERIFIED), or a writable route config turns
into access to the tray's control wire (launch/stop/login operations — capability of that wire
not probed). The directory mount (rw) also lets the container replace the socket.
Fix: give the router a dedicated, narrow socket (route registration only), mounted as a file,
read-only directory; bind Caddy admin to a unix socket or disable it; confirm 2019/9090 are not
listening on 10.0.42.10.

---

## MEDIUM

### M1. Runtime secret files are mode 0444; inside containers they are readable by every uid
Evidence:
```
$ ls -la /run/user/1000/tillandsias/secrets      (dir 0700)
-r--r--r-- tillandsias-ca-key                      (PRIVATE KEY, proxy MITM intermediate)
-r--r--r-- tillandsias-vault-tls-key               (PRIVATE KEY)
-r--r--r-- tillandsias-vault-approle-git-mirror-agent-visual-chess-38310-<uuid>  ({"role_id","secret_id"})
-r--r--r-- tillandsias-vault-token-claude-login-tillandsias-claude-login-38310   (hvs.<REDACTED>, 95 bytes)
$ podman exec tillandsias-vault ls -la /run/secrets
-r--r--r-- tlatoani vault tillandsias-vault-tls-key
```
Impact: host side is protected only by the parent dir. In-container, any process regardless of
uid reads the token/key (in the forge image the agent itself runs as the same uid, so the Vault
token file is directly agent-readable — expected for login, but then its policy is the whole
boundary). Podman's native secrets (`podman secret ls` is empty) are not used.
Fix: 0400 owner-only; prefer `podman secret` with `uid=,mode=0400`; response-wrapped single-use
secret_id for AppRole; short TTL + `token_num_uses` on login tokens.

### M2. Long-lived plaintext credentials on disk outside Vault
Evidence:
```
~/.config/tillandsias/host-push/macuahuitl.approle.json  0600  {'role_id': 36 chars, 'secret_id': 36 chars}  (2026-10-02)
~/.config/tillandsias/host-push/macuahuitl.ed25519       0600  OPENSSH PRIVATE KEY — `ssh-keygen -y -P ''` succeeds: UNENCRYPTED
~/.config/tillandsias/host-push/macuahuitl.ed25519-cert.pub  Key ID "host-macuahuitl|approle", principal til:host-push:macuahuitl,
     valid 2026-10-02 13:52→14:23 (expired), critical: force-command, source-address 10.0.42.0/24
~/.cache/tillandsias/ca-key.pem                           0600  PRIVATE KEY for "Tillandsias CA" (self-signed root, CA:TRUE, 2026-10-26→2036-10-23, no nameConstraints)
~/.local/share/tillandsias/nix-cache/cache-priv.key, nix-cache.key  0600
```
Impact: the AppRole secret_id is a standing credential that mints push certs; the cert is
well-constrained and short-lived (good) but the thing that mints it is not. The 10-year root CA
key lives unencrypted in a *cache* directory (backup tools and cache cleaners treat it as
disposable/non-sensitive). Today's Vault wipe (M4) probably invalidated the AppRole, leaving a
dead credential nobody will clean up.
Fix: keep the AppRole secret_id in the keyring or re-issue per use via the tray; move the root
CA key out of `~/.cache` (keyring or `~/.local/state` 0700) and add nameConstraints; delete
stale host-push material on Vault re-init.

### M3. SELinux confinement disabled on every container; no memory limits
Evidence: every CreateCommand has `--security-opt label=disable`; `Mem=0` on all;
forge-image and vault/proxy rootfs writable (`RO=false`); host context is `unconfined_t`.
Good: `--cap-drop ALL`, `no-new-privileges`, private pid/user ns, pids-limit set, default seccomp
(not overridden).
Impact: with keep-id (container uid == host uid 1000) the SELinux MCS label is the main
remaining barrier after a runtime/kernel escape or a mis-scoped bind mount; it is switched off
fleet-wide. Inference additionally gets `--device nvidia.com/gpu=all`.
Fix: use `:z/:Z` relabeling (already written on some mounts, where it is a no-op) instead of
`label=disable`; `--read-only` + tmpfs for forge/proxy/vault as already done for router/git;
set `--memory`.

### M4. Unseal-key mismatch silently destroys the whole credential store
Evidence (`~/.cache/tillandsias/tray-launch-20261111.log`):
```
[vault-entrypoint] FATAL: unseal request returned HTTP 400: wrong key
sign-in-again: the stored unseal share does not open the Vault store, so the store was wiped and Vault starts empty
```
`entrypoint.log`: `security barrier initialized: stored=1 shares=1 threshold=1`, `root token generated` at 18:16:10Z.
Impact: anything that can write one keyring item (same-uid process, keyring reset, restore from
backup) wipes all sign-ins with no confirmation — a cheap denial-of-service, and it forces the
operator through fresh OAuth logins (a phishing-friendly moment). It also happened on this very
start, so the cause of the mismatch is itself worth explaining.
Fix (if wipe is the intended policy): keep it, but record why the share mismatched, move the old
store aside for one generation instead of deleting, and surface it as a tray dialog rather than a log line.

### M5. Debug logging enabled on production services
Evidence: proxy `--env DEBUG_PROXY=1`, git mirror `--env GIT_TRACE=1`, inference `--env OLLAMA_DEBUG=1`.
Proxy access log (`podman logs tillandsias-proxy`) records full decrypted (ssl-bump) URLs:
`GET https://release-assets.githubusercontent.com/github-production-release-asset/…/ceb6<REDACTED>?`.
Query strings are stripped (0 lines with `?k=v`, 0 `Authorization`), and a pattern scan of all
tillandsias logs found no token-shaped strings — so nothing is leaking today.
Impact: OLLAMA_DEBUG logs prompt content; GIT_TRACE can print credential-helper invocations and
remote URLs; these reach `podman logs`, journald and `--diagnostics`.
Fix: default the three flags off; enable only under `--debug`.

### M6. All services share one flat enclave network (lateral movement surface, UNVERIFIED reachability)
Evidence: vault 10.0.42.3:8200, proxy .4:3128-3135, router .10, git mirror .11, inference
(Ollama, no auth) :11434, nix-cache :5000, login/forge containers — all on `tillandsias-enclave`,
`no_proxy` includes `10.0.42.0/24`. Egress exists only via proxy (enclave `internal=true`; proxy
is dual-homed to `tillandsias-egress`) — good.
Impact: a forge can address Vault's API directly (auth is then the only control), the Ollama API
(model pull/delete/create is unauthenticated in Ollama), and other projects' services (H2).
Fix: per-project networks joined only to the shared services they need; put an authenticating
front on Ollama or restrict it to generate/embed.

---

## LOW

### L1. Session transcripts and logs are world-readable files
`~/.local/state/tillandsias/attached-sessions/*.log` (0644, up to 1 MB of agent terminal
transcript), `known-cloud-projects` (40 private repo names), `~/.cache/tillandsias/*.log`,
`vault-audit/entrypoint.log` (0644). Directory chain `~/.local/state` is 0755; only `~` (0710 +
ACL `user:qemu:--x`) stops other users — and the `qemu` user can traverse. Fix: 0700 on the
state dir, 0600 on transcripts; umask 077 in the tray.

### L2. Vault audit log unbounded
`~/.cache/tillandsias/vault-audit/audit.json` is 527 MB, no rotation, owned by subuid 524388
(mode 0600 — good, HMAC'd contents not inspected). Survives the store wipe, so it spans Vault
generations. Fix: rotate/cap; decide whether it should die with the store.

### L3. Vault secret store lives in `~/.cache`
`~/.cache/tillandsias/vault-data` and `vault-audit` are bind-mounted `:U`. Cache dirs are
excluded from backups and are fair game for cleaners. Fix: `~/.local/state` or a named volume.

### L4. World-writable socket and tmpfs
`/run/user/1000/tillandsias/push-events/default/24402.sock` is `srw-rw-rw-` (parent chain
0700 at /run/user/1000 saves it); the per-project push-events dir is mounted into the mirror.
Vault has `--tmpfs /run/vault-handover:mode=0777`. Fix: 0600 / 0700.

### L5. Model cache is shared read-write into the inference container; no licence files beside weights
`-v ~/.cache/tillandsias/models:/home/ollama/.ollama/models:rw`; weights 0644
(sdxs09, sdxl_lightning_4step, flux1-schnell Q4/Q8, t5xxl, clip_l, ae). No `*licen*` file within
3 levels of the model dir. A compromised inference container can swap weights for every project.
Fix: ro mount except during an explicit pull; store licence text + digest next to each artefact.

### L6. Tray inherits ambient session secrets
`/proc/24402/environ` contains `CLAUDE_CODE_MESSAGING_TOKEN`, `SSH_AUTH_SOCK` (names only read).
Not seen propagated into any container env. Fix: scrub the environment at tray start.

---

## INFO

- I1. Stale objects: exited `tillandsias-org-preview` (python:3.12-slim, 127.0.0.1:8088),
  3 `keepid-warm-test` containers in Created, 8 `tillandsias-browser-net-*` and 2 studio networks,
  ~40 named volumes incl. mirrors of projects not running.
- I2. Vault: `Mlock: supported: true, enabled: false` although `CAP_IPC_LOCK` is the one added
  capability; Vault 1.18.5 (Feb 2025 build). `/v1/secret/metadata/` without token → 403 (good).
- I3. Non-Tillandsias host listeners seen: 0.0.0.0:22, *:3389 (gnome-remote-desktop),
  0.0.0.0:27500 (owner not visible), host Ollama 127.0.0.1:11434.

## What held up (negative results)
- No credential in any container env, CreateCommand, image env, image history, or `ps` args.
- Token-pattern scan (GitHub, Vault hvs., Anthropic, JWT, PEM, Bearer, x-access-token) over
  all Tillandsias logs/state: zero real hits.
- No podman socket, no host D-Bus, no home directory mounted into any running container.
- Enclave network is `internal`; only the proxy is dual-homed.
- All containers: cap-drop ALL, no-new-privileges, non-root user, private userns.
- Preview CA trusted by host browsers is name-constrained to `DNS:localhost`, pathlen 0.
- Host-push SSH cert: 30-minute validity, force-command, source-address pinned.
- `~/.config/gh/hosts.yml` holds no oauth_token line (token in keyring).
