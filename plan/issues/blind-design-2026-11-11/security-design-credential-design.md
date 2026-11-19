# Credential design — one broker, zero credentials in forges

Blind design from the promise. One sentence: **the forge never receives a
credential; it receives a place to send a request, and a host-side broker
decides whether a credential-using relay performs that request upstream.**

Citations are from the author's knowledge; not re-fetched this session.

## 1. Why a single broker

Credential handling gets messy when each service grows its own answer: one
reads an env var, one mounts a file, one keeps a token in its config
directory, one shells out to a helper. Each answer has its own storage, its
own lifetime and its own leak path, and "where are the operator's credentials
right now?" stops having an answer.

The rule that prevents this: **there is exactly one component that can turn
nothing into a credential (the broker), exactly one place a long-lived
credential rests (the vault), and exactly one shape in which a credential
leaves the broker (a short-lived, scoped token handed over a unix socket to a
relay the broker itself started).** A new service is integrated by writing a
relay and a scope definition, never by teaching a container to hold a secret.

## 2. Invariants

These are the testable claims. `audit-checklist.md` tests each one.

| ID | Invariant |
|----|-----------|
| I1 | No credential exists in plaintext at rest anywhere: host disk, VM disk, volumes, image layers, container configs, logs. |
| I2 | No upstream credential (long- or short-lived) is ever present inside a forge: not in env, files, process memory, network responses, or agent-visible output. |
| I3 | A forge has no route to the internet except through a gateway that enforces a per-forge destination allowlist. |
| I4 | Each forge has a distinct identity assigned by the broker and derived from the channel, never from anything the forge asserts. Every capability is scoped to (project, forge, service, verb). |
| I5 | Anything inside a forge that looks like a token is a forge-local handle that is useless from any other network position. |
| I6 | Upstream tokens held by relays are minimally scoped and short-lived (target ≤ 1 h) wherever the provider permits; long-lived material lives only in the vault. |
| I7 | Cloud-cost and destructive actions execute only after a fresh OS user verification bound to a digest of the exact action; the prompt is rendered by the host from structured fields. |
| I8 | A vault that cannot be opened or fails its integrity/rollback check is wiped. There is no recovery path and no plaintext fallback. |
| I9 | Every issuance, use, denial, approval and revocation produces an audit event in a hash-chained log that contains no secret values and that no forge can read or write. |
| I10 | Images, models and docs are used only after digest + signature verification; failure is closed. (`supply-chain.md`) |
| I11 | A licence-restricted artefact is unavailable to a project without a valid acceptance record for that project. (`supply-chain.md`) |
| I12 | Forges are rootless and unprivileged, with no container-engine socket and no host mounts beyond the project. |
| I13 | No broker or relay endpoint is reachable by another local user or from the LAN. |
| I14 | Stopping a forge invalidates its handles immediately; revoking a grant invalidates upstream tokens as fast as the provider allows, and the vault copy at once. |

## 3. Components

**Vault.** One file. AEAD (XChaCha20-Poly1305 or AES-256-GCM) over a small
record store. The data key is random, never derived from anything guessable,
and wrapped by the platform keystore:

| Platform | Wrapping | Release condition |
|----------|----------|-------------------|
| macOS | Keychain item / Secure Enclave key with `SecAccessControl` [C1] | Device unlocked, this device only, not synced |
| Windows | DPAPI-protected blob, or a TPM-backed Windows Hello key [C2] | User logged in |
| Linux | Secret Service item in the login collection [C3]; where a TPM2 is present, additionally sealed with `systemd-creds` or equivalent [C4] | Login keyring unlocked |
| Linux, no keyring (headless, minimal WM) | FIDO2 authenticator `hmac-secret`, or an operator passphrase through Argon2id [Q6] | Operator present at unlock |

If none is available the broker runs **without a vault**: grants live in
`mlock`ed memory for the session and are lost at exit. This is the standing
rule applied literally — losing a credential beats storing it unencrypted.

The vault header carries a monotonic generation counter that is also stored in
the keystore item. Mismatch, AEAD failure, or keystore refusal ⇒ the broker
deletes the vault file, emits `vault.wiped`, and the tray shows "sign in
again". No retries with other keys, no export, no "recovery phrase" (I8).

**Broker.** A host process started by the tray, same user. It:
- owns the vault and is the only process that ever holds unsealed long-lived
  material;
- performs provider login flows (§7) and refreshes;
- mints short-lived upstream tokens and forge-local handles;
- evaluates policy (scope × verb × approval class);
- raises OS user-verification prompts;
- writes the audit log.

It listens on a unix socket in the user's runtime directory (mode 0600, parent
0700) or an ACL'd named pipe on Windows. No TCP. Hardening: no core dumps, not
ptrace-attachable where the OS allows it, secrets in locked memory and zeroed
on drop, never logs request bodies.

On macOS/Windows the broker stays on the **host** (where the keystore and the
biometric API are); a thin forwarder inside the VM exposes one unix socket per
relay. The VM never stores anything.

**Relays** (credential-using services). One instance per project per service,
started by the broker from a digest-pinned, signature-verified image:

| Relay | What the forge sees | What it does upstream |
|-------|---------------------|-----------------------|
| Egress gateway | The only default route and DNS resolver; provider base URLs point at it | Allowlisted HTTPS; for provider hosts, adds the `Authorization` header |
| Git relay | An ordinary git remote with no authentication | Validates ref policy, scans the pack for secrets, then pushes to the one configured GitHub repo |
| Deploy relay | A small API: `plan`, `deploy`, `status`, `rollback` for this project's Cloudflare target | Calls Cloudflare with a child token |
| Inference | An OpenAI-compatible endpoint on the project network | Nothing; no upstream, no credential |
| Artefact fetcher | `fetch model X@digest` | Downloads, verifies (I10), checks licence record (I11), mounts read-only |

A relay gets its token by calling the broker over a socket mounted **only**
into that relay. It keeps the token in memory, refetches before expiry, and
never writes it. A relay has no shell, no package manager, and no writable
filesystem besides tmpfs.

**Forge.** Holds nothing. See §6.

## 4. Identity and scoping

*Identity is where you are plugged in.* At forge creation the broker creates:

- a per-project internal network (no gateway route; `--internal`) [C5];
- the project's relays on that network;
- a forge ID (random, 128-bit) recorded as `{project, forge, image digest,
  agent kind, created}`.

A relay identifies the caller by the network/socket the request arrived on —
one relay instance serves one project, so "who is asking" is structural. Where
several forges of the same project share relays, each forge gets its own unix
socket bind-mounted from a per-forge directory, and the relay keys on the
socket. Nothing sent *in* the request — header, hostname, client cert generated
inside the forge — is trusted as identity (I4). This is the SPIFFE idea
(attested workload identity, not bearer assertion) reduced to what a single
machine needs [C6].

*Scope* is a tuple the broker stores per project:

```
grant:    {provider, account, upstream_scope, obtained_at, by_login_flow}
binding:  {project, grant, service, verbs[], constraints}
          e.g. {proj-A, github:alice, git, [fetch, push],
                {repo: alice/proj-A, refs: "refs/heads/agent/*", force: false}}
          e.g. {proj-A, cloudflare:acct1, deploy, [plan, deploy:preview],
                {project: proj-a-site, production: approval}}
          e.g. {proj-A, anthropic:alice, model, [messages],
                {models: [...], budget_per_day: N}}
```

Bindings are created by the operator in the tray (never by a forge), default
to the narrowest useful set, and are per project: opening project B does not
inherit project A's bindings even for the same account. A forge can *ask* for
a binding; that produces a tray request the operator may grant, and widening is
approval-class.

## 5. Lifetimes, rotation, revocation

| Material | Where | Lifetime | Rotation |
|----------|-------|----------|----------|
| Vault data key | Keystore-wrapped | Until wipe | Re-wrapped on every vault write generation; full re-key on OS user password change where the keystore signals it |
| GitHub App user refresh token | Vault | Provider-set (months); rotates on every refresh [C7] | Each refresh replaces it; reuse of an old one is a compromise signal |
| GitHub upstream push token | Git relay memory | ≤ 1 h (installation tokens) or 8 h (user-to-server) [C7][C8] | Refetch at 80 % of TTL |
| Provider OAuth access token | Gateway memory | Provider-set (hours) | Broker refreshes; refresh token stays in vault |
| Provider API key (when OAuth is unavailable) | Vault; a copy in gateway memory | Until operator rotates | Tray reminds at N days; rotation = new login |
| Cloudflare parent token | Vault | Operator-set expiry | Tray reminds |
| Cloudflare child token | Deploy relay memory | Minutes, `expires_on` set, resource-scoped to the one project [C9] | Minted per deploy |
| Forge-local handle | Forge | Life of the forge | New forge, new handle |
| Approval assertion | Broker memory | Single use, ≤ 60 s, bound to action digest | n/a |

Revocation, three levels:

1. **Forge stop / kill** — broker drops the forge ID; relays refuse its socket;
   effective immediately (I14).
2. **Unbind project** — broker deletes the binding and tears down the project's
   relays; their in-memory tokens die with them; where the provider has a
   revoke endpoint for the short-lived token the broker calls it.
3. **Panic / sign out of provider** — broker revokes upstream (GitHub
   `DELETE /applications/{client_id}/grant` or token; Cloudflare token delete;
   provider logout), deletes the vault record, tears down all relays using it.
   If upstream revocation fails (offline), the tray says so in plain words and
   keeps retrying; the local copy is gone regardless.

Vault wipe (I8) is level 3 for everything, minus the upstream calls it can no
longer authenticate — the tray then lists the provider pages where the operator
should revoke by hand.

## 6. How a secret reaches its consumer — and what never happens

The consumer of a credential is a **relay**, never an agent. Path:

```
vault ──(unseal in broker memory)──► broker ──(unix socket, in-memory reply,
   short-lived scoped token)──► relay memory ──(TLS)──► provider
```

The forge side of each integration:

| Need | Forge configuration (contains no secret) | Notes |
|------|------------------------------------------|-------|
| Anthropic / OpenAI-compatible APIs | `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` (or the tool's provider `baseURL`) set to the gateway; API key set to a fixed public placeholder such as `forge-local` | Agent CLIs document gateway/base-URL operation [C10][C11][C12]. The placeholder is not a secret and is identical in every install, so finding it in a transcript is harmless (I5) |
| Subscription-login agents | The CLI's login is performed by the broker, outside the forge (§7); the forge runs the CLI in gateway mode | Whether each vendor's CLI and terms permit this is open [Q1][Q2] |
| git push/fetch | `origin` = `http://git.forge.internal/<project>.git`; no credential helper, no SSH key, no `gh` login | The relay is the only thing that knows GitHub exists |
| GitHub API (PRs, issues) | A narrow relay API or allowlisted REST paths through the gateway, which adds the token | Generic authenticated proxying of `api.github.com` is **not** offered — too broad (confused deputy) |
| Cloudflare | `deploy` CLI shim that talks to the deploy relay | `wrangler` with a token is never run in a forge |
| Local models | `http://inference.forge.internal/v1` | No credential |

Channels a secret must never touch, and the mechanism that guarantees it:

| Channel | Guarantee |
|---------|-----------|
| Environment variables (`podman inspect`, `/proc/*/environ`, child processes, crash dumps) | Broker and relays take secrets only over the socket; forge and relay container specs are generated by one function that has no secret-typed input |
| Image layers / build args / labels | Images are built with no network credentials at all; builds that need private fetches go through the gateway. Release pipeline scans every layer for token patterns |
| Files on volumes, agent config dirs (`~/.claude`, `~/.codex`, `~/.local/share/opencode`, `~/.config/gh`) | Nothing writes them: logins do not happen in forges. Forge home is ephemeral or, if persisted, scanned on stop |
| `podman secret` | Not used with the default `file` driver, which stores secret data unencrypted on disk [C13] |
| Logs (broker, relay, gateway, podman, journald) | Secret values are a distinct type with no `Display`/`Debug`; gateway logs method, host, path template, status, byte counts — never headers or bodies |
| Shell history | No workflow asks the operator or an agent to paste a token into a shell. Logins are browser/device flows (§7). API keys, where unavoidable, are entered in a tray secure-input field |
| Agent transcripts / model context | Follows from I2: nothing in the forge to print. Relay error messages are sanitised (upstream error bodies can echo tokens) |
| Clipboard | Tray never copies a secret out; paste-in fields clear the clipboard after read where the OS permits |
| Swap / hibernation | Locked memory in broker and relays; residual without FDE [Q9] |
| Upstream (pushing a secret into a repo or a deploy) | Git and deploy relays run a secret scanner over outgoing content and refuse on a hit |

### What an agent may see

- that a service exists and which verbs it may use;
- its own forge ID and project name;
- the account *label* a binding uses (e.g. "GitHub: alice") — needed to write
  sensible commit trailers and PR text;
- success/failure and sanitised upstream errors;
- "approval required / denied / expired" as a result, with a retry hint.

### What an agent may never see or do

- any upstream token, key, cookie, refresh token, App private key, vault
  content, or keystore handle;
- another project's bindings, existence, or audit events;
- the audit log;
- the approval prompt's rendering inputs beyond its own structured request;
- the broker socket, the container-engine socket, the host home;
- a generic "sign this" / "fetch this URL with credentials" primitive;
- its own bindings in writable form.

## 7. Per-provider login flows

All logins are initiated from the tray, run in the broker, and end with the
grant in the vault. None runs in a forge. Public-client OAuth follows the
native-app BCP: system browser, PKCE, loopback redirect on an ephemeral port
or device code; never an embedded webview [C14][C15][C16][C17].

**GitHub.** A GitHub App (not a classic OAuth app, not a PAT) with user
authorization via the device flow [C8][C16]. The operator installs the App on
chosen repositories — GitHub's own UI is the scoping consent. The broker holds
the user refresh token; for each project it obtains a token restricted to that
one repository and to `contents:write` (+ `pull_requests:write` if bound)
[C7]. Whether the product ships a shared public App or each operator creates
their own is open [Q3]; a shared App must be a public client with no embedded
client secret or private key. Fallback: a fine-grained PAT limited to named
repos [C18], entered in the tray — long-lived, so flagged in the tray as the
weaker option. SSH keys and classic PATs are not supported.

**Model providers.** Preference order per provider:
1. OAuth/subscription login performed by the broker, with the gateway attaching
   the access token [Q1][Q2];
2. API key entered in the tray, scoped at the provider to a dedicated
   workspace/project with a spend limit where the provider offers one;
3. if a vendor's CLI can only authenticate by writing a token file in its own
   home and cannot use a gateway: that agent runs with a **per-forge,
   short-lived** credential if the provider can mint one; otherwise it is
   marked "unsupported under I2" and the operator must opt in per project with
   an approval, and the tray labels the forge as holding a live credential.
   This exception is the single sanctioned breach of I2 and must be visible,
   enumerable and auditable — never silent [Q2].

**GitHub Copilot.** Authenticates with the operator's GitHub identity; token
exchange is vendor-specific [Q5]. Treated as case 3 above until verified.

**Cloudflare.** The operator creates (or the broker creates via OAuth, if a
suitable public client exists [Q10]) a *parent* API token whose permissions
are limited to the account and to the products used (Pages/Workers, DNS for
named zones) plus permission to create tokens. The broker mints child tokens
with `expires_on` minutes ahead and resources narrowed to the one project
[C9]. Creating a new Cloudflare project, binding a custom domain, or a
production deploy are approval-class (I7); preview deploys within an existing
project are not, subject to a daily cap.

**Local inference.** No login. Model *downloads* from gated hubs use a hub
token held in the vault and used only by the artefact fetcher.

## 8. Approval (I7)

Approval-class verbs (initial list): create/delete cloud resources; production
deploy; DNS change; anything billed per use above a configured threshold;
force-push or delete of a non-agent ref; push that modifies CI/workflow files;
widening any binding; licence acceptance; the I2 exception in §7; vault export
(does not exist) — and any verb a relay author marks `cost` or `destructive`.

Flow:

1. Relay sends the broker a structured request: `{project, forge, verb,
   target, parameters, estimated_cost, reversible: bool}`.
2. Broker canonicalises it and computes `d = SHA-256(request ‖ nonce)`.
3. Tray renders a prompt **from the structured fields with fixed templates**.
   Free text supplied by the forge is shown, if at all, in a quoted,
   length-limited box labelled as written by the agent.
4. Broker invokes OS user verification with `d` in the reason/context:
   LocalAuthentication on macOS [C1], Windows Hello `UserConsentVerifier` or a
   Hello-key signature over `d` [C2], on Linux a FIDO2 assertion over `d` or
   polkit+fprintd [C19][Q7]. Where the OS offers a key that only signs after
   verification, the approval *is* a signature over `d` — preferred, because it
   is evidence rather than a boolean.
5. The assertion is single-use, expires in ≤ 60 s, and authorises exactly the
   request with digest `d`. The relay re-sends the request; the broker
   recomputes the digest before releasing the token.

No "approve all for this session". Time-boxed standing approvals are allowed
only for a *named verb on a named target* and are themselves approval-class,
listed in the tray, and expire. Biometric modalities are convenience
verifiers per NIST 800-63B, acceptable here because the factor being proven is
"the operator is at the machine", backed by the device passcode [C20].

## 9. Audit events (I9)

Append-only JSON lines, each `{seq, ts, prev_hash, event, project, forge,
service, verb, target, decision, reason, token_fp, approval_ref}`; `prev_hash`
chains records; the chain head is stored in the keystore so truncation is
detectable. `token_fp` is the first 8 hex of SHA-256 of the token — enough to
correlate with a provider's own audit log, useless for replay. Stored under
the operator's state directory, mode 0600; never mounted into any container.

Events: `vault.created|opened|wiped`, `login.started|completed|failed`,
`grant.refreshed|revoked|revocation_failed`, `binding.created|widened|removed`,
`forge.created|stopped`, `token.minted` (relay, scope, ttl),
`relay.request.allowed|denied` (verb, target), `egress.denied` (host),
`approval.requested|granted|denied|expired`, `scan.blocked` (secret found in
outgoing push/deploy), `exception.i2.enabled`, `artefact.verified|rejected`,
`licence.accepted|missing`.

Audit content is itself sensitive (repo names, hosts) but not secret; it is
readable by the operator in the tray and exportable. It never contains request
bodies, prompts, or header values.

## 10. Failure behaviour

| Condition | Behaviour |
|-----------|-----------|
| Keystore locked | Broker waits; forges run; credentialed verbs return "locked" |
| Vault unopenable / rollback detected | Wipe; re-login (I8) |
| Broker crash | Relays continue until token expiry; no new tokens; tray restarts broker |
| Relay crash | Verb fails; no fallback to direct egress |
| Provider refresh fails (revoked upstream) | Delete grant; tray asks for login |
| No user-verification capability on the host | Approval-class verbs are unavailable, not downgraded to a click [Q7] |

## References

- [C1] Apple LocalAuthentication; `SecAccessControlCreateFlags` — https://developer.apple.com/documentation/localauthentication , https://developer.apple.com/documentation/security/secaccesscontrolcreateflags
- [C2] Microsoft `UserConsentVerifier`; `KeyCredentialManager`; DPAPI — https://learn.microsoft.com/en-us/uwp/api/windows.security.credentials.ui.userconsentverifier , https://learn.microsoft.com/en-us/uwp/api/windows.security.credentials.keycredentialmanager , https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata
- [C3] Secret Service API — https://specifications.freedesktop.org/secret-service/latest/
- [C4] `systemd-creds` — https://www.freedesktop.org/software/systemd/man/latest/systemd-creds.html
- [C5] `podman network create --internal` — https://docs.podman.io/en/latest/markdown/podman-network-create.1.html
- [C6] SPIFFE concepts — https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/
- [C7] GitHub, generating installation and user access tokens; refreshing user access tokens — https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app , https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens
- [C8] GitHub, generating a user access token for a GitHub App (device flow) — https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app
- [C9] Cloudflare, create API tokens / create tokens via API — https://developers.cloudflare.com/fundamentals/api/get-started/create-token/ , https://developers.cloudflare.com/fundamentals/api/how-to/create-via-api/
- [C10] Claude Code, LLM gateway configuration and settings — https://docs.claude.com/en/docs/claude-code/llm-gateway , https://docs.claude.com/en/docs/claude-code/settings
- [C11] OpenAI Codex, authentication and configuration — https://developers.openai.com/codex/auth
- [C12] OpenCode, providers — https://opencode.ai/docs/providers/
- [C13] `podman secret create`, drivers — https://docs.podman.io/en/latest/markdown/podman-secret-create.1.html
- [C14] RFC 8252, OAuth 2.0 for Native Apps — https://www.rfc-editor.org/rfc/rfc8252
- [C15] RFC 7636, PKCE — https://www.rfc-editor.org/rfc/rfc7636
- [C16] RFC 8628, Device Authorization Grant — https://www.rfc-editor.org/rfc/rfc8628
- [C17] RFC 9700, OAuth 2.0 Security Best Current Practice — https://www.rfc-editor.org/rfc/rfc9700
- [C18] GitHub, fine-grained personal access tokens — https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens
- [C19] polkit; FIDO CTAP 2.1 — https://www.freedesktop.org/software/polkit/docs/latest/ , https://fidoalliance.org/specs/fido-v2.1-ps-20210615/fido-client-to-authenticator-protocol-v2.1-ps-20210615.html
- [C20] NIST SP 800-63B — https://pages.nist.gov/800-63-4/sp800-63b.html
