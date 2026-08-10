# DESIGN: SSH certificate authority for forge→mirror push (order 322) — AWAITING SIGNATURE

- Date: 2026-07-31
- Class: research/decision — the deliverable of order 322 `mirror-authenticated-push-transport`
- Owner host: linux (`linux-next`)
- Status: **UNSIGNED.** Order 451 stays `blocked` until The Tlatoāni signs §1.
- Amended 2026-08-10 (packet 606-bvnp `git-mirror-cross-project-service-identity`):
  shared aliases and the `sign/*` wildcard replaced with an opaque per-project
  mirror identity (D13), exact per-project client AND host roles/policies, exact
  certificate principals, and the negative two-project matrix (§4a) that must be
  green before 451 wires production sshd. Still UNSIGNED; the amendment changes
  no prior operator decision, it narrows authority.
- Transport already decided by the operator (plan/index.yaml order 322, event
  `2026-07-31T18:30:00Z`): **SSH, as a certificate authority with short-lived
  certs and rotation**, not `authorized_keys`. The `git://` accept-the-risk
  branch was removed by operator directive 2026-07-19 and is not reopened here.
- What this document adds: the credential-issuance design, which did not exist.
- Long-range CONTEXT (not authorization):
  `plan/issues/operator-vision-ai-cloud-region-2026-07-31.md`
- Prior evidence: `plan/issues/git-mirror-architecture-audit-2026-07-12.md`,
  `plan/issues/git-mirror-architecture-decision-2026-07-19.md`,
  `plan/issues/research-authenticated-forge-writes-restore-2026-07-19.md`,
  `cheatsheets/concurrent-git/git-mirror-enterprise-practices.md` §4, R7.

---

## 0. Verification ledger — WHERE each claim was checked

This repository's recurring defect class is *"verified where it was written is
not verified where it runs."* Every load-bearing claim below is tagged with the
context in which it was actually observed, and whether that is the context in
which it will run.

| # | Claim | Verified where | Same context as production? |
|---|---|---|---|
| V1 | Vault has **only** `approle` auth, `kv-v2` at `secret/`, and a file audit device enabled. No `ssh` mount. | `images/vault/entrypoint.sh:220-224` (source), and the on-disk barrier at `~/.cache/tillandsias/vault-data/logical/` holds exactly 2 mount UUIDs | Source is authoritative for a fresh boot. **Not** verified against the live server — the `tillandsias-vault` container is `Exited (137)` on this host and I did not start it (see §5). |
| V2 | The Vault `ssh` secrets engine mounts, generates an in-Vault CA, issues user and host certs, and `GET config/ca` returns **only** `public_key`. | `localhost/tillandsias-vault:sha256-534f4e79…`, Vault **v1.18.5**, `vault server -dev` in a throwaway container | Same binary, same image. Different config (dev mode, no TLS listener, no AppRole). |
| V3 | `allowed_users` does **not** glob: `til:forge-push:*` is rejected; `*` alone permits anything; an exact list works. | same throwaway Vault | same as V2 |
| V4 | `allowed_extensions:""` makes Vault refuse a `permit-pty` request; `max_ttl` is enforced server-side; `default_critical_options` puts `force-command` and `source-address` into the cert. | same throwaway Vault + `ssh-keygen -L` on the host | same as V2 |
| V5 | The Vault sign endpoint has **no** `key_id` request parameter, and `key_id_format` substitutes `{{role_name}}` and `{{token_display_name}}` but **not** `{{serial_number}}` or `{{token_metadata.*}}` (they render literally). | same throwaway Vault, cert decoded with `ssh-keygen -L` | same as V2 |
| V6 | A Vault token holding only `update` on `<mount>/sign/<role>` can sign but is **denied** `read` on `<mount>/config/ca`. | same throwaway Vault | same as V2 |
| V7 | OpenSSH CA semantics: cert-only auth (`AuthorizedKeysFile none` + `TrustedUserCAKeys`), principal mismatch denied, expired cert denied, host cert removes TOFU, `force-command` runs, `ExposeAuthInfo` hands the full cert to the forced command. | **Host**, OpenSSH 10.2p1, non-root `sshd` on 127.0.0.1:2222 as uid 1000 | **NO.** This is the host, not the alpine mirror container under `--read-only` + `--cap-drop=ALL`. See R1 in §5. |
| V8 | An **established** SSH session survives its certificate expiring mid-command (20 s cert, 45 s command, completed); the *next* connection is refused. | same host probe | same caveat as V7 |
| V9 | KRL revocation by serial works: `RevokedKeys` + `ssh-keygen -k` denies the revoked serial and admits a freshly issued one from the same CA and the same private key. | same host probe | same caveat as V7 |
| V10 | The **forge image already ships** `ssh`, `ssh-keygen`, `ssh-add`, `ssh-agent`; git 2.55.0; uid 1000 `forge`. | `podman run localhost/tillandsias-forge:v0.4.260730.2` | **Yes** — the live image forges run from. Note the Containerfile never names openssh; it arrives transitively. |
| V11 | The **mirror image already ships** `ssh`, `ssh-agent`, `ssh-add`, `ssh-keygen`, `vault`, `jq`, `git-receive-pack`; runs as uid 1000 `git`; **`sshd` is ABSENT** (`openssh-server` not installed). | `podman run localhost/tillandsias-git:latest` | **Yes** — the live mirror image. |
| V12 | `/vault/audit` is a container-layer directory, not a mounted volume (`/vault/file`, `/vault/logs`, `/vault/data` are). The `/vault/logs` volume is empty. | `podman inspect tillandsias-vault` + `podman run … ls /vault` | **Yes** — the live container's own mount table. |
| V13 | The enclave TLS CA private key sits at `/tmp/tillandsias-ca/intermediate.key`, mode **0644**, in a world-traversable directory, deliberately re-chmodded to 0644 on every call so squid can read it. | `crates/tillandsias-headless/src/main.rs:2231-2246` and `:2268-2276`, confirmed by `ls -la /tmp/tillandsias-ca/` on this host | **Yes** — live host state. |
| V14 | The forge is **not** credential-free today: `HOMEBREW_GITHUB_API_TOKEN` (the real GitHub token) is injected into every lane's environment. | `crates/tillandsias-headless/src/main.rs:11304-11311` | Source; visible to `podman inspect` at runtime. |

External knowledge used and **not** independently verified here is confined to
§5 R4–R6 and is flagged inline as `[EXTERNAL]`.

---

## 1. DECISION RECORD — for The Tlatoāni's signature

Each row: the choice, why, and the alternative rejected. Sign or amend §1; §2 is
the reasoning, §4 is what 451 builds.

### D1 — One CA per purpose: two Vault mounts, `ssh-client-signer` and `ssh-host-signer`

Stand up **two** `ssh` secrets-engine mounts, each with its own internally
generated **ed25519** signing key.

- **Why**: a single CA that signs both user and host certificates means
  compromise of the mirror's host-cert trust and compromise of client identity
  are the same event. Two mounts give two independent keys and two independent
  policy targets. Verified (V2) that both mount and generate cleanly on the
  shipped Vault v1.18.5, and (V4) that a host role refuses `cert_type=user`.
- **Rejected**: one mount with two roles. Cheaper, and role-level `cert_type`
  enforcement is real — but it collapses two blast radii into one key, and the
  mesh (order 563) will need to rotate host trust and client trust on different
  schedules.

### D2 — The CA private key is generated inside Vault and never exported

`config/ca` with `generate_signing_key=true`. Never `submit` an externally
generated key.

- **Why**: verified (V2) that `GET <mount>/config/ca` returns only
  `public_key` — there is no API path that yields the private half. The CA's
  blast radius therefore equals Vault's seal, and nothing else.
- **Rejected**: generating the CA key on the host with `ssh-keygen` and
  submitting it. That is precisely the existing enclave-TLS-CA pattern, whose
  private key is sitting at `/tmp/tillandsias-ca/intermediate.key` mode **0644**
  on this host right now (V13). Repeating it for the SSH CA would make the
  highest-value secret in the system world-readable in `/tmp`.

### D3 — Authorization lives in the **principal**; identity lives in the **key**

- Principal (one per project): `til:forge-push:<mirror-id>`, where `<mirror-id>`
  is the opaque per-project identity of D13 — never the plaintext project name.
  A rejected cert prints its principal into the *other* project's `sshd` log;
  with plaintext names that is a cross-tenant information leak, with opaque IDs
  it is noise. Readability cost: logs need one join against the attribution
  ledger's `project ⇄ mirror-id` mapping (recorded at mint time, D13), which is
  the same join the fingerprint already requires.
- Attribution: the lane's **certificate public-key fingerprint**
  (`SHA256:…`), recorded by the launcher at lane creation and logged by `sshd`.
- **Why**: verified (V3) that Vault's `allowed_users` is an exact list with no
  globbing, so an unbounded principal namespace would need an unbounded number
  of Vault roles. A small enumerable principal set is what the *server* checks;
  an unbounded identity belongs in a field the server only *records*. Verified
  (V5) that Vault will not accept a per-request `key_id`, and that
  `{{token_metadata.*}}`/`{{serial_number}}` are not substituted — so the key ID
  cannot carry the lane without extra token plumbing. Verified (V9) that the
  key fingerprint is stable across certificate re-issuance, which the serial is
  not.
- **Rejected**: principal `til:forge-push:<project>:<lane>`. Requires one Vault
  role per lane (V3), and the mirror's `AuthorizedPrincipalsFile` cannot
  enumerate lanes it has never heard of.
- **Rejected**: attribution by certificate serial alone. Correct but fragile —
  it changes on every renewal, so the ledger must be updated by whoever renews.

### D4 — Certificates carry **no extensions** and two critical options

Role: `allowed_extensions=""`, `default_extensions={}`,
`default_critical_options={"force-command": "<mirror receive wrapper>",
"source-address": "10.0.42.0/24"}`.

- **Why**: verified (V4) that Vault then *refuses* a `permit-pty` request and
  that both critical options land in the issued certificate. A stolen key+cert
  pair cannot open a shell, forward a port, or forward an agent; it can only run
  the receive wrapper, and only from the enclave subnet. This is the single
  cheapest containment control in the whole design. `source-address` is
  enclave-wide, so it does NOT separate project A from project B — per-project
  separation is carried by the exact principal (D3) and exact roles/policies
  (D12/D13); the subnet restriction is defense-in-depth against off-enclave use
  only (see the §2.3 note).
- **Rejected**: relying on `sshd`'s `ForceCommand` alone. Equivalent on a
  correctly configured server, but it is not carried *by the credential*, so it
  does not travel to the mesh's future servers.

### D5 — The forge never holds a private key: a per-lane `ssh-agent` sidecar

One sidecar container per forge lane, running from the **existing
`tillandsias-git` image** (V11 — it already has `ssh-agent`, `ssh-keygen` and
the `vault` binary; no new image). It generates its own ed25519 key on tmpfs,
publishes only the public key, holds the certificate, and exposes an
`ssh-agent` socket on a named podman volume that the forge mounts.
`SSH_AUTH_SOCK` points at it.

- **Why**: the forge gets a **signing oracle, not a secret**. `ssh-add -L`
  reveals the public key and certificate; the private half is unreadable and
  un-exfiltratable. This is the same shape as the established
  `git-credential-tillandsias` broker (order 319/424): the forge asks, something
  else holds. A named volume — not a host bind mount — keeps it identical on
  Linux podman, the macOS VZ guest, and WSL2, all of which run the same in-guest
  `tillandsias-headless` (`crates/tillandsias-vm-layer/src/vz.rs:542`).
- **Residual, stated plainly**: any process inside the forge can *use* the
  socket while the lane lives. Under D4 that buys exactly `git-receive-pack` on
  one project's mirror from inside the enclave — which is what the forge is
  entitled to do anyway. The oracle's power equals the lane's intended power.
- **Rejected**: private key on a tmpfs inside the forge. Simplest, and D4 makes
  a stolen key nearly worthless — but it is a *readable credential file in the
  forge*, which is the exact thing the operator asked to avoid.
- **Rejected**: running the per-lane agents inside the **mirror** container
  (zero new containers, reuses its Vault Agent). The server would hold every
  client's key, and the arrangement does not generalize to the mesh, where
  client and server are different machines. A rung that does not generalize is
  the wrong rung.

### D6 — The sidecar self-renews via Vault Agent AppRole; the launcher never handles the key

The sidecar gets an AppRole (`ssh-lane-signer-<mirror-id>`, per project — D12)
delivered exactly like `git-mirror-agent` is today — one podman secret, `uid=1000,gid=1000,mode=0400`,
split onto tmpfs by a bootstrap script, Vault Agent auto-auth, token in a tmpfs
sink. Its minted policy grants **only** `update` on
`ssh-client-signer/sign/<mirror-id>` (D12/D13 — the exact path, never a
wildcard).

- **Why**: verified (V6) that such a token can sign but is denied `read` on
  `config/ca`. The marginal blast radius of a compromised sidecar is nil: it can
  mint only the same principal, with the same forced command, with no
  extensions — i.e. exactly the certificate it already holds. And it reuses the
  litmus-pinned pattern (`images/git/vault-agent.hcl`,
  `images/git/vault-agent-bootstrap.sh`, `litmus:git-mirror-vault-agent-auto-auth`)
  rather than inventing a second one.
- **Rejected**: the launcher signs and pushes renewed certificates into the
  shared volume. Marginally tighter (the sidecar could not re-mint after
  expiry), but it requires a bespoke renewal loop in `tillandsias-headless` and
  a cert-reload watcher in the sidecar, and it duplicates the auto-auth
  machinery that already exists.

### D7 — TTLs

| Certificate | TTL | `max_ttl` | Renewal |
|---|---|---|---|
| Forge lane (user cert) | **30 min** | 1 h | sidecar re-signs at T−10 min |
| Mirror host cert | **24 h** | 48 h | mirror re-signs at start and every 8 h |
| Lane **key pair** | lifetime of the sidecar container | — | new key per lane launch |

- **Why 30 min**: the operator's stated requirement is "this principal, for this
  purpose, for ten minutes". 30 min with a 10-min renewal margin is the same
  property with three renewal attempts before failure, and it comfortably
  exceeds any single push (V8 shows an in-flight session is unaffected anyway).
- **Rejected**: an 8-hour cert matching the forge session. No renewer needed,
  but revocation would then depend entirely on the KRL, and it abandons the
  short-lived-credential property that is the reason a CA was chosen over
  `authorized_keys`.

### D8 — Revocation: TTL first, KRL second, and the KRL is the emergency stop

`sshd` gets `RevokedKeys <krl>`; the launcher maintains the KRL by serial and
can revoke a whole CA generation.

- **Why**: verified (V9) that a KRL by serial denies the revoked certificate
  while a fresh one from the same CA and the same private key is accepted, and
  that `sshd` logs `Authentication key … revoked by file …`. Vault's ssh engine
  publishes no CRL of its own — short TTL is its revocation story — so the KRL
  is the only mechanism that acts faster than expiry.
- **Rejected**: relying on TTL alone. A 30-minute window with no stop button is
  not acceptable for the component that will later gate cross-node compute.

### D9 — Host certificates, and TOFU treated as a defect

The mirror for project P presents a host certificate whose principal list is
exactly one name — its opaque per-project hostname `git-<mirror-id>` (D13).
The legacy shared aliases `tillandsias-git` / `git-service` are never certified
(they stop existing entirely under 659-8faj). Every client's `known_hosts`
carries one `@cert-authority` line for the host CA and nothing else.

- **Why**: verified (V7 case D) that without the `@cert-authority` line the
  connection fails with *"No ED25519 host key is known … Host key verification
  failed"* under `StrictHostKeyChecking=yes` — i.e. the host cert is exactly
  what removes the prompt. One line, generated from the CA public key, replaces
  per-host key distribution and survives mirror container recreation, which
  under the destroy-and-recreate directive happens constantly. **The forge's
  `~/.ssh` is an empty tmpfs by design** (`main.rs:5001-5004`, `:11119-11120`),
  so `known_hosts` must be delivered through the read-only global config, not
  written into `~/.ssh`.
- **Rejected**: pinning the mirror's raw host key. Every recreation of
  `tillandsias-git-<project>` invalidates it; the failure mode is a scary
  MITM warning that agents will be tempted to bypass.

### D10 — Two OpenSSH controls carry the transport-level gate

`sshd_config`: `AuthorizedKeysFile none`, `TrustedUserCAKeys <client-CA.pub>`,
`AuthorizedPrincipalsFile` containing exactly `til:forge-push:<mirror-id>`
(this project's opaque principal, one line, D3/D13),
plus `ForceCommand` to a receive wrapper.
Mirror repo config: `receive.denyNonFastForwards=true`,
`receive.denyDeletes=true`, `receive.fsckObjects=true`, applied on **every**
container start.

- **Why**: verified (V7) that `AuthorizedKeysFile none` makes a raw public key
  fail even when the same key has a valid cert available (case B), and that a
  CA-signed cert bearing the wrong principal is refused (case C). That is
  per-project containment by construction, not by convention.
- **The bug this fixes**: `images/git/entrypoint.sh:131-139` sets
  `receive.denyNonFastforwards false` and `receive.denyDeletes false` **inside
  the `if [ ! -d "$PROJECT_REPO" ]` block**, so today the mirror accepts force
  pushes and ref deletions locally, and any hardening added there will silently
  not apply to existing `tillandsias-mirror-<project>` volumes. This must move
  out of the init branch.
- **Rejected**: leaving ff-denial to GitHub's rejection of the relay push. That
  is the status quo, it protects upstream but not the mirror, and the packet's
  stated point is that the transport enforces the gate.

### D11 — Attribution reaches the audit trail through three independent channels

1. `sshd` at `LogLevel VERBOSE` logs
   `Accepted certificate ID "…" (serial N) signed by … CA …` and the
   `ED25519-CERT SHA256:<fingerprint>`.
2. The forced-command wrapper reads `$SSH_USER_AUTH` (`ExposeAuthInfo yes`) and
   exports `TILLANDSIAS_PUSH_KEY_FP` / `TILLANDSIAS_PUSH_PRINCIPAL` /
   `TILLANDSIAS_PUSH_SERIAL` before `exec git-receive-pack`; `pre-receive`
   inherits them and adds them to the existing `--log-git` accountability
   records alongside the ref transaction.
3. Vault's audit device independently records every `sign` call.
- **Why**: verified (V7 case A) that the forced command really does receive the
  full certificate blob via `$SSH_USER_AUTH`, and (V9) that `sshd` logs the ID,
  serial and CA. Three channels means attribution survives losing any one.
- **Blocking caveat**: channel 3 is currently worthless. `/vault/audit` is a
  container-layer directory, not a volume (V12), so Vault's audit records die
  with the container — under a destroy-and-recreate discipline, permanently.
  Fixing that is in scope for 451 (§4 T9).

### D12 — Only two identities per project may ever ask the CA to sign

Per project P with opaque identity `<mirror-id>`: `ssh-lane-signer-<mirror-id>`
(the sidecar, `update` on `ssh-client-signer/sign/<mirror-id>` only — the exact
path, never `sign/*`) and `ssh-host-signer-<mirror-id>` (the mirror, `update` on
`ssh-host-signer/sign/host-<mirror-id>` only). Nothing else — not `tray-policy`,
not `forge-policy`, not the root token path. Because the project set is dynamic,
these exact policies are MINTED by the launcher at mirror provision (the same
code path that creates the per-project roles, §2.3) from a template with the
`<mirror-id>` substituted — no wildcard policy file ever ships, so there is no
wildcard to forget to remove. A project-A sidecar asking `sign/<mirror-id-B>`
receives 403 (§4a M2), which is the property the zero-trust audit's correction
1 demands.

- **Why**: verified (V6) that a sign-only token cannot read `config/ca`. Note
  that `tray.hcl` today is `path "secret/*" { … }` — it grants everything under
  `secret/` and would **not** reach an `ssh-client-signer/` mount, which is the
  correct outcome and must stay that way.
- **Rejected**: letting the launcher sign through the existing
  `vault_kv_get_via_exec` root-token path (`vault_bootstrap.rs:844`). It works
  today and needs no new AppRole, but it puts a root-capable path across the
  highest-value mount in the system.

### D13 — Opaque per-project mirror identity (`mirror-id`): minted random, persisted in Vault, distributed by the launcher

Added 2026-08-10 by 606-bvnp. Every per-project artifact above — DNS hostname,
role names, policy paths, certificate principals — is keyed by one opaque token:

- **Form**: `mirror-id` = 12 bytes from the host CSPRNG, lowercase base32hex
  without padding (20 chars). Hostname = `git-<mirror-id>` (24 chars, a single
  valid DNS label, assignable as a podman `--network-alias`).
- **Minted RANDOM, never derived.** A hash of the project name (salted or not,
  if the salt is shared) is enumerable by any tenant that can guess project
  names — and project names are chosen by humans to be guessable. Randomness is
  the only derivation with nothing to guess from.
- **Persisted in Vault kv**: `secret/mirror-identity/<project>` (kv-v2), written
  ONCE by the launcher at first mirror provision for that project, read on every
  later launch. Why Vault and not a podman volume label: (a) the launcher must
  have the value server-side anyway, at the moment it writes the per-project
  host role's `allowed_domains` and mints the per-project policies (D12) — Vault
  is already in that transaction; (b) a volume label is casually enumerable by
  anything that can reach the podman socket and is dumped wholesale by
  diagnostics tooling, while the kv path is policy-gated and audited; (c) labels
  die with `podman volume rm` while the kv entry survives mirror-volume
  recreation, so identity is stable across the destroy-and-recreate discipline.
  Under a full `--reset-guest` both Vault and volumes are wiped together: a NEW
  mirror-id is minted on next launch, which is correct — identity restarts with
  the trust root. No forge-reachable policy may read
  `secret/data/mirror-identity/*`; extend the
  `litmus-vault-policy-forge-cannot-read-github-token.yaml` shape to pin that.
- **Distribution**: the launcher resolves (mint-or-read) the mirror-id inside
  `ensure_shared_git_and_inference_for_launch`, and it flows exclusively through
  the single derivation function that slice 659-8faj introduces for the DNS
  identity — that function is the one swap point; `build_git_run_args` (alias +
  hostname), the forge env (`TILLANDSIAS_GIT_SERVICE`, already-existing plumbing
  honoured by `shell-helpers.sh`), and `write_forge_gitconfig`'s `insteadOf`
  targets all consume its output and never re-derive it. The attribution ledger
  records `project ⇄ mirror-id` at mint time (D3's join).
- **Migration**: existing installs have no stored identity. First launch after
  upgrade: kv path absent → mint, store, proceed; repo volume data is untouched
  because the identity appears nowhere inside the repository. The shared aliases
  are simply no longer assigned (659-8faj) and the negative fixture (§4a M1)
  proves they no longer resolve.
- **Stated plainly**: knowing another project's hostname must NEVER be
  sufficient to reach or authenticate to its mirror. The enforced controls are
  the certificates and exact roles/policies (D10, D12); DNS opacity is
  defense-in-depth against enumeration and accidental cross-routing, not a
  security boundary.

### Open questions that genuinely need The Tlatoāni

Everything else in this document was answerable by reading the code or by
running the probes in §0. These four are not.

- **Q1 — The forge is not credential-free today; does 322 close that, or note
  it?** `main.rs:11304-11311` injects the real GitHub token into **every** forge
  lane as `HOMEBREW_GITHUB_API_TOKEN` (V14), visible to `podman inspect` and to
  any agent in the container; provider API keys are injected the same way under
  a recorded deviation budget (`litmus-forge-secret-capability-contract.yaml`
  step 5). So the "forge holds zero readable credentials" invariant that this
  packet is designed against is **already false**, and `openspec/specs/tillandsias-vault`
  has been amended to the weaker "no *broad* Vault token". This design does not
  make it worse and does not fix it. Is closing the env-token hole part of 451,
  or a separate packet? *(Recommendation: separate packet — it is a brew
  convenience token with one consumer, and bundling it doubles 451's blast
  radius.)*
  *2026-08-10 (606-bvnp): remains OPEN and operator-gated; deliberately not
  resolved by this amendment.*
- **Q2 — Sidecar per lane, or a single per-project sidecar running one agent
  per lane?** Per-lane is cleaner and is what D5 specifies; per-project is one
  container instead of N and reuses one AppRole. Attribution works either way.
  This is a resource-vs-isolation call, and forges are already heavy.
  *2026-08-10 (606-bvnp): remains OPEN and operator-gated. The operator
  re-raised exactly this question on 2026-08-10 while asking about multi-agent
  enclave topology ("each their own git-mirror, or share one") — the mirror
  itself is settled (one per project, order 443); the signing-sidecar layer is
  this Q2 and still needs The Tlatoāni's call.*
- **Q3 — CA rotation cadence, and who is allowed to trigger it.** `sshd` can
  trust several CAs at once, so overlap rotation is mechanically easy. But
  rotating the client CA invalidates every outstanding lane cert within one TTL,
  and rotating the host CA requires every client's `known_hosts` line to be
  regenerated. Proposal: annual scheduled rotation plus an operator-triggered
  emergency rotation; the emergency path is a capability that should probably
  need human presence (the "encrypted OK button" of the vision addendum).
- **Q4 — Does `git://` keep serving fetch?** The 2026-07-19 appendix says yes
  (read-only `--export-all` upload-pack on the enclave). That remains correct,
  but it means the enclave keeps one unauthenticated service. Confirm the
  read path stays anonymous rather than also moving to SSH. *(Recommendation:
  keep it — it is the property that lets clone work before any credential
  exists, and it eliminates all CA/credential config from the read path.)*

### Signature

```
Decision record for order 322 — SSH certificate authority, forge → mirror push.

Signed: ______________________  (The Tlatoāni)      Date: ____________

Amendments, if any:
```

Order 451 remains `blocked` until this block is filled in.

---

## 2. Design body

### 2.1 What exists today (facts, with file:line)

- The forge pushes over **`git://tillandsias-git/<project>`** to an anonymous
  `git daemon --export-all --enable=receive-pack` on 9418
  (`images/git/entrypoint.sh:345-352`). No authentication of any kind.
  *(Corrected 2026-08-10: the mirror's direct egress attachment was removed by
  the 606-9wqd work — it now sits on the enclave network only; upstream relay
  traffic goes through the proxy. The dual-homing this paragraph originally
  described no longer exists.)*
- The URL rewrite reaches the forge through a host-generated, read-only-mounted
  `/home/forge/.gitconfig` (`main.rs:7739-7862`, mounted at `:5116-5124` and
  `:11241-11247`), with guest-side fallbacks in
  `images/default/lib-common.sh:476-537` and `:751-826`.
- `pre-receive` validates ledger YAML and then relays the exact ref transaction
  to GitHub with `git push --atomic` (`images/git/pre-receive-hook.sh:293-304`,
  `images/git/relay-refs.sh:168`), authenticating through
  `git-credential-tillandsias` → `vault-cli` → `secret/github/token`. The forge
  push succeeds only if GitHub already accepted.
- **There is no fast-forward denial on the mirror.**
  `entrypoint.sh:131-139` sets `denyNonFastforwards false` / `denyDeletes false`
  at volume-fresh init only.
- **There is no push attribution.** The only "identity" is a
  `prepare-commit-msg` trailer written from `$TILLANDSIAS_AGENT_NAME`
  (`lib-common.sh:332-368`) — agent-supplied and trivially forgeable — and one
  host-wide git author identity shared by every concurrent lane
  (`main.rs:7667-7691`).
- The mirror image has **no `sshd`** (V11). The forge image **does** already
  have the full ssh client toolchain (V10).
- Vault has no `ssh` mount (V1), 12 policies on disk of which the image loads 4
  (`images/vault/Containerfile:31-34`, `entrypoint.sh:195-198`) and the host
  bootstrap loads all 12 (`vault_bootstrap.rs:3246-3257`).

### 2.2 The invariant, as it is actually written

Two places express it, and they no longer agree with the code:

- `openspec/specs/forge-offline/spec.md`: *"Forge containers SHALL NOT have any
  credential mounts… WHEN an AI agent inside the forge attempts to access
  `/run/secrets/` or `~/.config/gh/` THEN these paths SHALL NOT exist."*
- `openspec/specs/git-mirror-service/spec.md`: *"No AppRole value, Vault token,
  GitHub token, D-Bus socket, keyring API, bind-mounted token file, or askpass
  helper SHALL cross into a forge container or appear in process arguments,
  environment variables, or logs."*
- Reconciled weaker form, `openspec/specs/tillandsias-vault/spec.md`
  (`tillandsias-vault.security.forge-offline@v2`): forges SHALL NOT receive a
  **broad** Vault token; a named provider-scoped one is permitted.

The design in §2.4 satisfies the *strong* reading for the SSH credential: an
agent socket is not in the enumerated list and, unlike everything in that list,
**cannot disclose the secret it guards**. That distinction is not currently
written down anywhere, and 451 must write it: *a signing oracle that cannot
disclose key material is permitted; key material is not.* Without that
amendment the new mount will read as a spec violation to the next auditor.

Q1 in §1 records the fact that the strong reading is already violated
independently of this work.

### 2.3 Standing up the Vault engines

```
# mounts (idempotent, same enable_endpoint shape as images/vault/entrypoint.sh:220-224)
POST /v1/sys/mounts/ssh-client-signer   {"type":"ssh"}
POST /v1/sys/mounts/ssh-host-signer     {"type":"ssh"}

POST /v1/ssh-client-signer/config/ca    {"generate_signing_key":true,"key_type":"ed25519"}
POST /v1/ssh-host-signer/config/ca      {"generate_signing_key":true,"key_type":"ed25519"}

# one client role PER PROJECT, named by the opaque mirror-id (D13)
# (V3: allowed_users does not glob — exact principal, never the project name)
POST /v1/ssh-client-signer/roles/<mirror-id>
{
  "key_type": "ca",
  "allow_user_certificates": true,
  "allowed_users": "til:forge-push:<mirror-id>",
  "default_user": "git",
  "allowed_extensions": "",
  "default_extensions": {},
  "default_critical_options": {
    "force-command":  "/usr/local/bin/tillandsias-receive",
    "source-address": "10.0.42.0/24"
  },
  "ttl": "30m", "max_ttl": "1h",
  "key_id_format": "{{role_name}}|{{token_display_name}}"
}

# one host role PER PROJECT — exact identity, no shared aliases
# (amended 2026-08-10 by 606-bvnp; the previous shared roles/mirror-host with
#  allowed_domains "tillandsias-git,git-service" encoded the shared-alias
#  defect into the host CA and is withdrawn)
POST /v1/ssh-host-signer/roles/host-<mirror-id>
{
  "key_type": "ca", "allow_host_certificates": true,
  "allowed_domains": "git-<mirror-id>",
  "allow_bare_domains": true, "allow_subdomains": false,
  "ttl": "24h", "max_ttl": "48h"
}
```

Both roles are created at mirror provision time by the launcher (the project
set is dynamic, so they cannot be baked into the image), keyed by the mirror-id
that slice 659-8faj's derivation function supplies — that function is the single
swap point for the DNS identity and these roles alike.

`10.0.42.0/24` is `DEFAULT_ENCLAVE_SUBNET` (`main.rs:1034`); when
`TILLANDSIAS_ENCLAVE_SUBNET` overrides it the role must be written with the
effective value, or `source-address` will lock every lane out. Note that the
subnet is ENCLAVE-WIDE: project A's forge and project B's forge both sit inside
`10.0.42.0/24`, so `source-address` contributes NOTHING to inter-project
separation. What separates projects is the exact principal (D3), the exact
per-project roles above, and the exact policies below; `source-address` stays
in the certificate purely as defense-in-depth against use from outside the
enclave.

Policies are PER PROJECT and therefore MINTED at provision time, not shipped as
static files (amended 2026-08-10 by 606-bvnp — the earlier draft shipped a
static `ssh-lane-signer.hcl` containing `path "ssh-client-signer/sign/*"`,
which is cross-project signing authority: a project-A sidecar could request a
project-B certificate. That wildcard is withdrawn; no policy containing
`sign/*` may ever be written to the server):

```hcl
# ssh-lane-signer-<mirror-id> — the per-lane ssh-agent sidecar of ONE project
path "ssh-client-signer/sign/<mirror-id>" { capabilities = ["update"] }

# ssh-host-signer-<mirror-id> — the mirror of ONE project
path "ssh-host-signer/sign/host-<mirror-id>" { capabilities = ["update"] }
```

The launcher writes both through `sys/policies/acl/<name>` in the same
transaction that creates the roles (§2.3 above) and mints the AppRoles (D6),
substituting the literal `<mirror-id>` — the template lives in Rust next to
`provision_approle_roles` (`vault_bootstrap.rs`), not under
`images/vault/policies/`, precisely so the static-file lanes
(`Containerfile` COPY list, `entrypoint.sh` `load_policy`, `Policy::all()`,
`embedded_hcl_matches_image_files_on_disk`) are not in play. IF any future rung
does add a static ssh policy file, it must be added to ALL of: the
`images/vault/Containerfile` COPY list (which today copies only 4 of 12
policies — the known silent-divergence trap), the entrypoint's `load_policy`
calls, and `Policy::all()`.

Neither minted policy may read `config/ca`, `config/*`, or `roles/*` — verified
(V6) that this is enforced, not merely conventional.

### 2.4 Credential flow, end to end

```
tillandsias-headless (launcher, in-guest on every platform)
  │  0. resolves mirror-id: mint-or-read secret/mirror-identity/<project> (D13)
  │  1. ensures BOTH per-project Vault roles exist (client <mirror-id>,
  │     host host-<mirror-id>) and mints both exact policies (D12)
  │  2. mints ssh-lane-signer AppRole material  ── podman secret, uid=1000 mode=0400
  │     (identical to mint_git_mirror_vault_auto_auth, main.rs:2760-2787)
  ▼
tillandsias-sshagent-<project>-<lane>        [image: tillandsias-git, alt entrypoint]
  │  3. Vault Agent auto-auth → tmpfs token sink
  │  4. ssh-keygen -t ed25519 on tmpfs        ← private key is born here and dies here
  │  5. publishes lane.pub to the shared volume
  │  6. POST ssh-client-signer/sign/<mirror-id>, valid_principals=til:forge-push:<mirror-id>
  │  7. ssh-add key+cert into ssh-agent; socket on the shared named volume
  │  8. re-signs at T−10m, ssh-add again
  ▼  (named volume: /run/tillandsias-ssh/agent.sock)
tillandsias-<project>-forge-<lane>           SSH_AUTH_SOCK=/run/tillandsias-ssh/agent.sock
  │  git push  → ssh git@git-<mirror-id> → cert auth, no key material present
  ▼
tillandsias-git-<project>                    sshd (non-root, uid 1000 git, port 2222)
     TrustedUserCAKeys / AuthorizedPrincipalsFile / ForceCommand
     → tillandsias-receive → git-receive-pack → pre-receive → relay → GitHub
```

The launcher records `{lane, project, mirror_id, mode, container,
key_fingerprint, created_at}` in the accountability log at step 5; that is the
attribution ledger the mirror's logs join against (and the `project ⇄ mirror-id`
mapping that keeps opaque principals readable, D3/D13).

### 2.5 TTL, rotation, and what happens to in-flight work

Verified (V8): OpenSSH validates a certificate **at authentication time only**.
A session that authenticated one second before expiry runs to completion — a
20-second certificate carried a 45-second command to a clean exit. So:

- A push already in flight when the cert expires **completes normally**. There
  is no mid-transfer teardown to design around.
- The next `git push` on an expired cert fails at connect with
  `Permission denied (publickey)`.
- Therefore the only real requirement is that renewal (D7) stays ahead of
  expiry, and that **failure is loud**. If the sidecar cannot renew, pushes must
  fail with a message that names the cause — never silently fall back to
  `git://`, which is exactly the "silent degradation" class the 2026-07-19
  decision document identifies as this subsystem's cross-cutting defect.
- Clock skew: on every platform the forge, the sidecar and the mirror are
  containers on one kernel, so they share a clock and skew is zero. **This stops
  being true in the mesh**, where nodes are separate machines and a skew
  allowance becomes mandatory — recorded in §3.

### 2.6 Revocation

Vault's ssh engine publishes no CRL; short TTL is its story. That is not
sufficient for a credential that will later gate cross-node compute, so `sshd`
also carries `RevokedKeys /srv/git/.ssh/krl`. Verified (V9): building a KRL with
`ssh-keygen -k -f krl -s <ca.pub> <spec>` denies the revoked serial, admits a
freshly issued certificate over the same private key, and logs
`Authentication key … revoked by file …`.

Three revocation granularities, all available from the same file:
`serial: <n>` (one certificate), `serial: <a>-<b>` (a range — useful because
Vault's serials are random, so ranges are only useful with a recorded ledger),
and revoking a CA key outright (kills every certificate it ever signed).

The KRL lives in the mirror's `/srv/git` volume so it survives container
recreation, and is regenerated by the launcher.

### 2.7 Pre-receive gating and fast-forward denial

The point of the packet. Three layers, in order of who can bypass them:

1. **Transport** — `sshd` refuses any connection without a CA-signed cert
   bearing this project's principal (V7 cases B, C, E). No principal, no
   session, no `git-receive-pack` process.
2. **Command** — `force-command` in the certificate (D4) plus `ForceCommand` in
   `sshd_config` means the only thing a valid cert can run is the receive
   wrapper. `SSH_ORIGINAL_COMMAND` is recorded, then discarded; a client asking
   for `git-upload-archive`, a shell, or `git-receive-pack /srv/git/otherproject`
   gets the wrapper's fixed target instead.
3. **Repository** — `receive.denyNonFastForwards=true`,
   `receive.denyDeletes=true`, `receive.fsckObjects=true`, applied on **every**
   start (fixing `entrypoint.sh:131-139`, which applies them only on
   volume-fresh init and currently sets the first two to `false`). Then the
   existing `pre-receive` runs unchanged: ledger-YAML gate, then the atomic
   upstream relay whose failure fails the client push.

Layer 3 is where the "mirror must never rewind" guidance of
`cheatsheets/concurrent-git/git-mirror-enterprise-practices.md` R3 finally
becomes true; today only GitHub's own rejection provides it, and only for
upstream.

### 2.8 Attribution and audit

`ExposeAuthInfo yes` writes the authenticating credential to a file named by
`$SSH_USER_AUTH`; verified (V7 case A) that the forced command can read it and
that it contains the full certificate. The wrapper parses it with
`ssh-keygen -L -f -` and exports:

```
TILLANDSIAS_PUSH_KEY_FP=SHA256:…       # stable per lane      → joins the ledger
TILLANDSIAS_PUSH_PRINCIPAL=til:forge-push:<mirror-id>
TILLANDSIAS_PUSH_SERIAL=<n>            # changes per renewal  → joins the KRL
TILLANDSIAS_PUSH_KEY_ID=<mirror-id>|token-…
```

(The opaque principal and key ID resolve to a project through the launcher's
`project ⇄ mirror-id` mapping, D13 — one join, same as the fingerprint.)

`pre-receive` inherits them and emits them on the existing `--log-git`
accountability records next to the ref transaction, so "which lane pushed which
refs" is one grep. `sshd` at `LogLevel VERBOSE` records the same facts
independently.

**The Vault-side audit channel is broken today and must be fixed with this
work**: the file audit device is configured at `/vault/audit/audit.json`
(`images/vault/vault.hcl`, `entrypoint.sh:224`) but `/vault/audit` is a
container-layer directory — the mounted volumes are `/vault/file`,
`/vault/logs` and `/vault/data` (V12). Every sign request is recorded into a
layer that the destroy-and-recreate discipline throws away.

### 2.9 CA blast radius and containment

The client CA becomes the highest-value secret in the system: whoever holds it
can mint an identity for anything the CA is trusted for. Containment, in the
order it actually bites:

1. **The key never exists outside Vault** (D2, verified V2). There is no file to
   chmod wrong. Contrast the existing enclave TLS CA, whose private key is at
   `/tmp/tillandsias-ca/intermediate.key` mode **0644** on this host right now
   (V13) because squid needs to read it — that is the pattern this design
   explicitly refuses, and it is a live example of how a CA key degrades when it
   lives in a file.
2. **The CA's blast radius is exactly Vault's seal.** Compromise requires
   compromising the unseal path (`/run/secrets/tillandsias-vault-unseal`,
   HKDF-derived from machine-id + installation UUID). That is a pre-existing,
   already-analysed boundary, not a new one.
3. **Only two identities may sign** (D12), each restricted to one endpoint and
   denied `config/ca` (V6). Neither can enumerate roles or read the CA.
4. **What a stolen certificate buys is bounded by the certificate itself**
   (D4): no extensions, a forced command, and a source-address restriction to
   the enclave subnet. Verified (V4) that Vault refuses to issue anything wider
   through that role.
5. **Recovery is designed, not improvised**: revoke the CA generation in the
   KRL, rotate `config/ca`, and let `sshd` trust both generations during the
   overlap. Because host and client CAs are separate (D1), a client-CA
   compromise does not force every `known_hosts` line to be rewritten.
6. **Residual, stated**: a compromised *launcher* can create sidecars and
   therefore obtain certificates. That is unavoidable — the launcher decides
   what runs. The mitigation is that it cannot obtain a *wider* certificate than
   the role allows, and every issuance is audited (once §2.8 is fixed).

---

## 3. What the mesh packet must inherit from this

**Ledger correction first**: order 322's event says the mesh half is filed as
"560/561/562". It is not. Orders 560/561/562 are forge tooling fixes (ruby,
policy-binary discoverability, litmus podman preflight). The mesh packets are
**563** `mesh-identity-plane-research`, **564** `node-discovery-and-uptime-affinity`,
**565** `production-posture-no-network-tunnel-only`. Order 563's own outcome text
also refers to "the CA design (560)". Both references should be corrected to 563.

Five things 563 inherits, and must not re-decide:

1. **Authorization in the principal, identity in the key** (D3). Verified (V3)
   that Vault's `allowed_users` is an exact list, so the mesh's principals must
   also be a small enumerable set — `til:node-join:<class>`,
   `til:compute:<capability>` — with node identity carried as the key
   fingerprint. A mesh design that puts node IDs in principals will need one
   Vault role per node.
2. **The same CA, different roles.** That was the operator's whole argument for
   paying the CA cost now. 563 adds roles to `ssh-client-signer`, not a second
   mount, unless it needs a genuinely different blast radius.
3. **A signed certificate proves WHO, not WHAT.** This design gets away with
   authentication-only because `force-command` collapses the authorization
   question to a single verb on a single repository. The mesh cannot do that —
   "launch a container here" is an open verb — so 563 owes an authorization
   model, which is already its first exit criterion.
4. **Clock skew becomes real.** §2.5's zero-skew assumption holds only because
   every party is a container on one kernel. Cross-node certificate validation
   needs a skew allowance and a stated time source.
5. **The agent-socket pattern generalizes; the sidecar's placement does not.**
   D5's rejected alternative (agents inside the mirror) was rejected precisely
   because the mesh separates client and server. The per-lane sidecar becomes
   the node-local identity agent.

Nothing else about the mesh — discovery, uptime affinity, cross-node compute,
the Cloudflare production posture — is designed here.

---

## 4. What order 451 must implement

In dependency order. Each rung has a named closure.

- **T1 — Vault engines.** Mount `ssh-client-signer` and `ssh-host-signer` and
  generate both CAs at boot, in the same idempotent style as
  `images/vault/entrypoint.sh:220-224`. The per-project roles (client
  `<mirror-id>`, host `host-<mirror-id>`) are NOT boot-time work: the launcher
  creates them at mirror provision, keyed by D13's mint-or-read mirror-id.
  Closure: a litmus asserting both mounts exist and that `config/ca` returns a
  public key and no private key.
- **T2 — Policies.** Mint `ssh-lane-signer-<mirror-id>` and
  `ssh-host-signer-<mirror-id>` per project at provision time via
  `sys/policies/acl/` (template in Rust next to `provision_approle_roles` —
  no new static `.hcl` files, so the Containerfile-COPY/`Policy::all()`
  divergence trap is not in play; if a static file IS ever added it must go to
  the `COPY` list, `load_policy`, and `Policy::all()` together). Closure: a
  litmus in the shape of `litmus-vault-policy-forge-cannot-read-github-token.yaml`
  proving a lane-signer token can sign via its own exact path, receives 403 on
  the sibling's path (§4a M2), and cannot read `config/ca`; plus a source-level
  guard that no server-side policy ever contains `sign/*`.
- **T3 — `openssh-server` in the mirror image.** `images/git/Containerfile`
  currently has `openssh-client` only (V11). Add `openssh-server`; keep
  `--read-only` rootfs and `--cap-drop=ALL`, so `sshd` must run as uid 1000
  `git` on a **high port** (2222) with all writable state on the existing
  `/tmp` tmpfs or the `/srv/git` volume. **This is the highest-risk step —
  see R1 in §5. Verify it inside the container before building anything on it.**
- **T4 — Host certificate at mirror start.** The mirror requests a host cert
  from `ssh-host-signer/sign/host-<mirror-id>` using its existing Vault Agent
  token, for exactly the principal `git-<mirror-id>` (D9), writes it beside
  the host key, and re-requests every 8 h. Closure: a fixture asserting the
  presented host key is a certificate for exactly that one principal and that a
  client with only the `@cert-authority` line connects with
  `StrictHostKeyChecking=yes`.
- **T5 — `sshd_config`.** `AuthorizedKeysFile none`, `TrustedUserCAKeys`,
  `AuthorizedPrincipalsFile` written per project at start containing exactly
  `til:forge-push:<mirror-id>` (one line, opaque, D3),
  `ForceCommand /usr/local/bin/tillandsias-receive`, `ExposeAuthInfo yes`,
  `AllowTcpForwarding no`, `AllowAgentForwarding no`, `PermitTTY no`,
  `RevokedKeys`, `LogLevel VERBOSE`.
- **T6 — Receive wrapper.** Parses `$SSH_USER_AUTH`, exports the four
  `TILLANDSIAS_PUSH_*` variables, execs `git-receive-pack` on the **fixed**
  project path, ignoring `SSH_ORIGINAL_COMMAND`'s target.
- **T7 — Repository hardening.** Move `receive.denyNonFastforwards` /
  `receive.denyDeletes` out of the `if [ ! -d … ]` block at
  `images/git/entrypoint.sh:131-139`, flip both to `true`, add
  `receive.fsckObjects=true`. Closure: a fixture that upgrades an **existing**
  mirror volume and proves a force push is refused — the init-only placement is
  the exact reason this needs an upgrade fixture, not a fresh-volume one.
- **T8 — ssh-agent sidecar.** New entrypoint script in the existing
  `images/git` image (V11: `ssh-agent`, `ssh-keygen`, `vault` already present —
  no new image). Vault Agent auto-auth reusing `vault-agent.hcl` /
  `vault-agent-bootstrap.sh`; keygen on tmpfs; sign via the exact
  `ssh-client-signer/sign/<mirror-id>` path its minted policy names (D12 — a
  403 from any other path is correct behavior, §4a M2); `ssh-add`; renewal
  loop; socket on a named volume. Launcher wiring in `tillandsias-headless`:
  create the volume, mint the AppRole, start the sidecar before the forge,
  record the key fingerprint and mirror-id in the attribution ledger, tear both
  down together.
- **T9 — Persist the Vault audit device.** Mount a volume at `/vault/audit`
  (or repoint the device at the already-mounted `/vault/logs`). Without this,
  D11's third attribution channel does not exist (V12).
- **T10 — Forge wiring.** Mount the socket volume, set `SSH_AUTH_SOCK`, and
  change the `insteadOf` target in `write_forge_gitconfig`
  (`main.rs:7802-7804`) from the per-project mirror URL to
  `ssh://git@git-<mirror-id>:2222/srv/git/<project>` **for push only** —
  the anonymous protocol stays the fetch path (Q4), itself addressed at the
  per-project hostname once 659-8faj lands (the shared-alias `git://` URL form
  is retired with the aliases). `known_hosts` with the `@cert-authority`
  line must be delivered through the read-only global config, because
  `~/.ssh` is an empty tmpfs (D9). Also reckon with `export_ssh_env()` in
  `images/default/lib-common.sh:3098-3153`, which every forge entrypoint calls
  and which probes `~/.ssh` for identity files — dead today against the tmpfs,
  and a live hazard once ssh is in the push path.
- **T11 — Staged migration.** One lane behind a flag with a fetch/push parity
  fixture; soak; **the full §4a negative two-project matrix green is the gate
  for flipping the default** — no lane flips while any row of it is red or
  unbuilt; then remove `--enable=receive-pack` from
  `images/git/entrypoint.sh:345-352` and rewrite
  `openspec/litmus-tests/litmus-git-mirror-no-anonymous-daemon-write.yaml` to
  assert the write path is authenticated (its current text explicitly defends
  the daemon receive-pack as the interim path and must be retired with it).
- **T12 — Spec amendments.** `forge-offline` and `git-mirror-service` must state
  that *a signing oracle that cannot disclose key material is permitted; key
  material is not* (§2.2), or the new socket reads as a violation.
- **T13 — Fail loud.** A litmus that removes the agent socket and asserts the
  push fails with a named cause and does **not** fall back to `git://`.

### §4a — The negative two-project matrix (added 2026-08-10, 606-bvnp)

Two REAL simultaneous projects, A and B (product-shaped containers, not
hand-built stand-ins — the 659-8faj audit showed a probe image's `nslookup`
inverting a finding; use `getent ahostsv4` for every DNS row). Every row must
be an executable fixture with a pass/fail exit code, and ALL rows must be green
before T11 flips any lane to production sshd. This is the packet's exit
criterion 1–4 made enumerable:

| # | Fixture | Must hold |
|---|---|---|
| M0 | Positive control | A's and B's lanes each clone/fetch/push their own mirror successfully, concurrently. |
| M1 | DNS identity (delivered by 659-8faj's fixture) | `getent ahostsv4 git-<id-A>` returns exactly ONE A record; same for B; `tillandsias-git` and `git-service` resolve to NOTHING. |
| M2 | Vault signing 403 | A's lane-signer token: `sign/<id-A>` → 200; `sign/<id-B>` → 403 permission denied (clone the `litmus-vault-policy-forge-cannot-read-github-token.yaml` shape). Symmetric for B. |
| M3 | Client cert cross-rejection | A's valid cert (principal `til:forge-push:<id-A>`) presented to B's sshd → denied (principal not in B's `AuthorizedPrincipalsFile`), and `sshd` logs the refusal. |
| M4 | Host cert exactness | The host cert B's mirror presents carries exactly one principal, `git-<id-B>` (`ssh-keygen -L`); a client connecting to `git-<id-A>` that is answered with B's cert MUST fail host verification. |
| M5 | Fixed repository path | A's cert with `SSH_ORIGINAL_COMMAND` naming B's repo path still lands in A's fixed repository — the wrapper ignores the requested target (T6). |
| M6 | Audit completeness | After M0/M2/M3/M5, the audit records carry project, lane, principal, fingerprint, serial, and refs — and SURVIVE a mirror/Vault container recreation. Blocked on T9: `/vault/audit` is a container-layer directory today (V12) and dies on recreate; M6 cannot pass until T9 lands. |
| M7 | Identity confidentiality | From inside A's forge, B's mirror-id is not discoverable: not in A's env, not in A's gitconfig, and `secret/data/mirror-identity/*` unreadable through every forge-reachable policy (D13). |

Rows M2/M3/M5/M7 are the "project A must never mint or reach project B" claim;
M1/M4 are the identity-exactness claim; M6 is the attribution claim. M0 keeps
the matrix honest — a broken stack passes every negative test.

Not in scope for 451: the mesh (563/564/565), the `HOMEBREW_GITHUB_API_TOKEN`
env injection (Q1), and the pre-receive relay's upstream auth, which is correct
and unchanged.

---

## 5. Could not verify — and why

- **R1 — `sshd` running non-root inside the alpine mirror container under
  `--read-only` + `--cap-drop=ALL`.** This is the design's biggest single
  assumption and the one most likely to fail in the way this repo keeps failing.
  I verified the full CA flow with a non-root `sshd` **on the host**
  (OpenSSH 10.2p1, uid 1000, port 2222 — V7/V8/V9), which is *not* the context
  it will run in. I could not reproduce it in the container because
  `openssh-server` is not installed in `localhost/tillandsias-git:latest` (V11)
  and **this sandbox has no network**, so `apk add openssh-server` fails with a
  DNS error. Specific risks 451 must retire before building on T4–T7: whether
  `sshd` starts as uid 1000 with a read-only rootfs (host key, PID file and
  `/run/sshd` must all be on tmpfs or the `/srv/git` volume); whether it needs
  any capability that `--cap-drop=ALL` removes; and OpenSSH's privilege-separation
  behaviour when the authenticating user equals the running user. Recipe:
  add `openssh-server` to `images/git/Containerfile`, rebuild, then run the exact
  probe in this document's §0 V7 inside `podman run --read-only --cap-drop=ALL
  --user 1000` and require all five cases to pass **there**.
- **R2 — The live Vault server's mount table.** V1 rests on the entrypoint
  source and on the barrier having exactly two logical mount directories. The
  `tillandsias-vault` container is `Exited (137)` on this host and starting it
  would perturb the operator's unseal/handover state, which I judged out of
  bounds for a research packet. Confirmable in one command when the stack is
  next up: `vault secrets list` should show `cubbyhole/`, `identity/`,
  `secret/`, `sys/` and nothing else.
- **R3 — Cross-platform behaviour on macOS (VZ guest) and WSL2.** Everything
  here was exercised on Linux/podman. The design deliberately avoids host paths
  — named podman volumes and podman secrets only — because
  `tillandsias-headless` runs in-guest on all three platforms
  (`crates/tillandsias-vm-layer/src/vz.rs:542`), but that is an argument, not an
  observation. The socket's uid/gid and SELinux label across the sidecar↔forge
  boundary under `--userns=keep-id` is the specific thing to check.
- **R4 — `[EXTERNAL]` OpenSSH's exact privilege-separation requirements for a
  non-root `sshd`.** I observed that it works on the host (V7) but did not read
  the source or the man page to establish *why*, so I cannot predict how it
  degrades in a container with no `CAP_SETUID`/`CAP_SYS_CHROOT`. Feeds R1.
- **R5 — `[EXTERNAL]` Whether OpenSSH ever re-validates a certificate after
  authentication** (e.g. on rekey). V8 shows a 45-second command completing
  under a 20-second certificate, which is strong evidence for "no", but a long
  push crossing a rekey boundary was not tested. If this were wrong, §2.5's
  "in-flight pushes complete" claim would need a mid-transfer failure story.
- **R6 — `[EXTERNAL]` Vault's ssh engine revocation surface.** I found no CRL
  or revocation endpoint and designed the KRL as the answer, but I did not
  exhaustively enumerate the engine's API. If a revocation primitive exists,
  D8 should prefer it over a launcher-maintained KRL.
- **R7 — Nothing here has been performance-tested.** SSH adds a handshake per
  push where `git://` had none. On a loopback-equivalent container network this
  should be single-digit milliseconds, but `transport-negligible-overhead-2026-06-30.md`
  exists because that assumption has been wrong before in this codebase.

---

## Appendix — reproducing the probes

Vault (throwaway container, no host state touched):

```sh
podman run --rm --entrypoint /bin/sh localhost/tillandsias-vault:<digest> -c '
  vault server -dev -dev-root-token-id=root -dev-listen-address=127.0.0.1:8200 &
  sleep 4; A=http://127.0.0.1:8200; H="X-Vault-Token: root"
  curl -s -H "$H" -X POST -d "{\"type\":\"ssh\"}" $A/v1/sys/mounts/ssh-client-signer
  curl -s -H "$H" -X POST -d "{\"generate_signing_key\":true,\"key_type\":\"ed25519\"}" \
       $A/v1/ssh-client-signer/config/ca
  # roles must be written through the JSON API: the CLI cannot express the
  # map-typed fields (default_extensions, allowed_user_key_lengths).
'
```

OpenSSH CA (host, all state under one scratch directory, `sshd` on
127.0.0.1:2222 as the invoking uid): generate `ca`, `hostkey` + host cert
(`-h -n tillandsias-git,127.0.0.1`), `lane` + user cert
(`-n til:forge-push:demo -O clear -O critical:force-command=…`), an
`AuthorizedPrincipalsFile` containing the principal, and a `known_hosts` holding
one `@cert-authority` line. The five cases that must hold: cert login succeeds
with no TOFU; the same key **without** its cert is denied; a cert with the wrong
principal is denied; an expired cert is denied; and without the
`@cert-authority` line the host is unknown under `StrictHostKeyChecking=yes`.
