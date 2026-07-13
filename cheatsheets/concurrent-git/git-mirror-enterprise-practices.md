---
tags: [git, mirror, credentials, replication, git-daemon, concurrent, enterprise, forge]
languages: [bash]
since: 2026-07-12
last_verified: 2026-07-12
sources:
  - https://git-scm.com/docs/gitcredentials
  - https://git-scm.com/docs/git-credential
  - https://git-scm.com/book/en/v2/Git-Tools-Credential-Storage
  - https://github.com/git-ecosystem/git-credential-manager
  - https://github.com/git-ecosystem/git-credential-manager/blob/release/docs/credstores.md
  - https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app
  - https://git-scm.com/docs/git-clone
  - https://git-scm.com/docs/git-config
  - https://git-scm.com/docs/git-push
  - https://git-scm.com/docs/githooks
  - https://git-scm.com/docs/git-daemon
  - https://git-scm.com/book/en/v2/Git-on-the-Server-Smart-HTTP
  - https://gerrit.googlesource.com/plugins/replication/+doc/master/src/main/resources/Documentation/config.md
  - https://docs.gitlab.com/user/project/repository/mirror/push/
  - https://docs.gitlab.com/user/project/repository/mirror/troubleshooting/
  - https://docs.gitea.com/usage/repo-mirror
authority: high
status: current
tier: research
summary_generated_by: "claude-opus-4-8 order-315 research"
committed_for_project: false
---
# Git Mirror — Enterprise Practices (order-315 research)

@trace plan/issues (order 315: git-mirror architecture audit)

**Use when**: designing or debugging the local bare-mirror hop between forge
containers and GitHub — credential isolation, mirror refspecs, durable relay,
protocol choice, and config delivery. Guiding principle for the target design:
**SIMPLICITY — DEFAULTS OVER CONFIGURATION; git-native primitives over scripts.**

All URLs below retrieved **2026-07-12**. Where a practice is contested or a
source only partially supports a claim, it is flagged inline.

---

## 0. TL;DR disposition table (maps to §6)

| Current Tillandsias pain | Industry default | Verdict |
|---|---|---|
| Mirror acks push, may silently lose upstream relay (post-receive relay) | post-receive **cannot** fail the push; use a visible async queue OR synchronous proxy | **Redesign** — post-receive is structurally wrong for must-succeed |
| Config via env mesh (`GIT_CONFIG_GLOBAL`, `GIT_SSL_CAINFO`, `insteadOf`) drifting across podman/VM/WSL2 | versioned `include.path`/`includeIf` files, not env | **Adopt includes** |
| Credentials injected into forge env | credential helper protocol keeps secrets in a **broker outside** the untrusted env | **Broker pattern** |
| `git://` daemon for the local hop | unauthenticated + unencrypted; OK only on closed trusted net, never for push | **Keep read paths, never push over it** |
| CA-trust env sprawl from MITM proxy | `http.sslCAInfo` in a versioned include, or trust at image-build time | **Bake trust, drop env** |

---

## 1. Credential architecture — keep secrets OUT of the forge

### 1.1 The helper protocol (git-native, no scripts needed)

Git speaks a tiny line protocol to a **credential helper** — a separate process
that Git invokes with one of three verbs on argv and a key/value record on
stdin/stdout ([gitcredentials(7)](https://git-scm.com/docs/gitcredentials),
[git-credential(1)](https://git-scm.com/docs/git-credential)):

| Verb | Meaning |
|---|---|
| `get` | return a matching `username`/`password` for the given `protocol`/`host`/`path` |
| `store` | persist a credential Git just used successfully |
| `erase` | drop a credential (e.g. after auth failure) |

Key properties Git guarantees:
- **Helpers chain.** Multiple `credential.helper` values are tried in turn; once
  a username + non-expired password is obtained, no more are consulted. A helper
  can emit `quit=1` to stop the chain. ([gitcredentials(7)](https://git-scm.com/docs/gitcredentials))
- **Helper string resolution:** leading `!` → shell snippet; absolute path → run
  verbatim; otherwise `git credential-<name>`. ([gitcredentials(7)](https://git-scm.com/docs/gitcredentials))
- **Password expiry:** helpers may return `password_expiry_utc`; Git treats
  expired secrets as absent — the native hook point for short-TTL tokens.

### 1.2 Built-in and OS helpers

| Helper | Storage | Note |
|---|---|---|
| `cache` | in-memory daemon, default 900 s | credentials never touch disk ([Pro Git 7.14](https://git-scm.com/book/en/v2/Git-Tools-Credential-Storage)) |
| `store` | plaintext `~/.git-credentials` | "discouraged" in the docs; last resort ([gitcredentials(7)](https://git-scm.com/docs/gitcredentials)) |
| `osxkeychain` / `wincred` / `libsecret` | OS keychain | single-factor username/password only ([Pro Git 7.14](https://git-scm.com/book/en/v2/Git-Tools-Credential-Storage)) |
| **Git Credential Manager (GCM)** | OS keychain + OAuth device-flow, GPG files | cross-platform (Win/mac/Linux), does OAuth/MFA, "not intended to be called directly by the user" ([git-ecosystem/GCM](https://github.com/git-ecosystem/git-credential-manager), [credstores.md](https://github.com/git-ecosystem/git-credential-manager/blob/release/docs/credstores.md)) |

### 1.3 Per-URL scoping

- `credential.<url>.helper` binds a helper to a host (or host+path). ([gitcredentials(7)](https://git-scm.com/docs/gitcredentials))
- `credential.useHttpPath = true` makes the **path** part of the lookup key, so
  `example.com/a.git` and `example.com/b.git` get distinct credentials — needed
  when one host serves many repos/identities. Off by default (host-only match).
  ([gitcredentials(7)](https://git-scm.com/docs/gitcredentials))

### 1.4 Keeping credentials out of an untrusted environment (the Tillandsias case)

The helper protocol is itself the isolation primitive: **the secret lives in the
broker process, only the broker's stdout crosses into the caller.** Patterns:

| Pattern | How | Source posture |
|---|---|---|
| **Credential broker/helper on the trusted side** | forge's Git calls a helper that reaches a socket/process *outside* the sandbox; the token is minted there and streamed for one operation | native protocol; the forge never holds a long-lived secret |
| **Ephemeral GitHub App installation tokens** | mint a `ghs_…` installation token; **expires after 1 hour**, scoped to specific repos + permissions | [GitHub Docs — installation access token](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app) |
| **Return short TTL via helper** | helper emits `password_expiry_utc`; Git auto-discards on expiry | [gitcredentials(7)](https://git-scm.com/docs/gitcredentials) |

Contrast with injecting a PAT into the forge's env: the secret is now inside the
blast radius, survives the operation, and leaks via `/proc`, crash dumps, and
child processes. The broker pattern is strictly better on all three.

---

## 2. Mirror semantics — what a read-write intermediary must NOT do

### 2.1 `--mirror` vs `--bare` vs explicit refspec

| | maps | refspec installed | intended use |
|---|---|---|---|
| `git clone --bare` | `refs/heads/*`, `refs/tags/*` | normal fetch refspec | serve a collaboration hub |
| `git clone --mirror` | **all** refs incl. `refs/remotes/*`, `refs/notes/*`, and sets `remote.origin.mirror=true` | `+refs/*:refs/*` | exact backup / one-way sync |
| bare + explicit refspec | only what you list | e.g. `+refs/heads/*:refs/heads/*` | controlled intermediary |

([git-clone(1)](https://git-scm.com/docs/git-clone))

### 2.2 Why `+refs/*:refs/*` is dangerous for a read-WRITE middle box

A mirror refspec is **force + prune over the entire ref namespace**. On fetch it
overwrites all local refs from the source; on push (`remote.<name>.mirror=true`,
i.e. `git push --mirror`) it *deletes on the remote any ref not present locally*.
([git-clone(1)](https://git-scm.com/docs/git-clone), [git-push(1)](https://git-scm.com/docs/git-push))

For an intermediary that both **receives** forge pushes and **relays** to GitHub,
mirror semantics mean a single missing local ref can wipe branches/tags upstream,
and the `+` (force) defeats any non-fast-forward protection. Community guidance is
blunt: *"Never push to a mirror unless you intend to sync all refs … use --mirror
only for backups/mirrors, not collaboration"* ([Graphite: bare vs mirror](https://graphite.com/guides/git-clone-bare-mirror)).

**Rule:** a read-write intermediary should relay with **explicit, non-force
refspecs** (`refs/heads/*:refs/heads/*`, tags listed explicitly), never `+refs/*`.

### 2.3 Fetch-mirror vs push-mirror

- **Fetch (pull) mirror:** intermediary pulls from upstream on a schedule/trigger;
  upstream is source of truth. Safe, read-only toward upstream.
- **Push mirror:** local is source of truth, changes flow *out* to upstream — this
  is the Tillandsias relay direction and the one that can lose data if the push
  toward GitHub is not confirmed. (GitLab/Gitea both model these as distinct
  objects; §3.)

### 2.4 Server-side integrity/safety knobs (defaults-over-config wins)

| Config | Effect | Recommend |
|---|---|---|
| `receive.denyNonFastForwards=true` | reject force-pushes into the mirror | **on** — mirror should never rewind |
| `receive.fsckObjects=true` | verify object integrity before accepting a push; blocks corrupt/malicious objects | **on** — cheap insurance ([Pro Git 8.1](https://git-scm.com/book/en/v2/Customizing-Git-Git-Configuration), [GitHub blog 2.6](https://github.blog/2015-09-29-git-2-6-including-flexible-fsck-and-improved-status/)) |
| `transfer.fsckObjects` | same check on both transfer directions | server-side hardening ([Pro Git 8.1](https://git-scm.com/book/en/v2/Customizing-Git-Git-Configuration)) |
| `git push --atomic` | **all refs update or none do**; fails if server lacks support | use on the relay to GitHub so partial relays can't happen ([git-push(1)](https://git-scm.com/docs/git-push)) |

`--atomic` is the git-native answer to "don't leave upstream half-updated."

---

## 3. Durable relay & ack — post-receive is the WRONG place

### 3.1 The structural bug

Per [githooks(5)](https://git-scm.com/docs/githooks):

> **pre-receive** runs *just before* refs are updated; its exit status determines
> success/failure of the whole update.
> **post-receive** runs *after* all refs are updated and **"does not affect the
> outcome of `git receive-pack`, as it is called after the real work is done."**

So a post-receive relay that pushes to GitHub runs **after the forge client has
already been told the push succeeded.** If the upstream push then fails, the client
never learns — this is exactly the silent-data-loss symptom. A non-zero
post-receive exit changes nothing the client sees.

**Corollary:** "must-succeed relay" and "post-receive" are mutually exclusive by
design. Two valid shapes instead:

| Design | Ack semantics | Failure surfacing |
|---|---|---|
| **Synchronous proxy / pre-receive relay** | ack the forge **only after** upstream accepts (relay inside pre-receive, or a proxying receive-pack) | forge push fails loudly on upstream failure; back-pressure is real |
| **Async with a VISIBLE, durable queue** | ack immediately, enqueue relay, retry with backoff, **expose queue depth + last-error + failed state** | operator/monitor sees stuck items; nothing is "acked and forgotten" |

The cardinal sin is neither of these: acking immediately with an *invisible*
fire-and-forget post-receive that can drop the event.

### 3.2 How the incumbents do it (all async, but with visibility + retry)

| System | Model | Retry / failure visibility | Source |
|---|---|---|---|
| **Gerrit replication plugin** | async queue; `replicationDelay` (default 15 s) before a push is scheduled | on offline remote, all pushes to that URL block and **retry continuously** unless `replicationMaxRetries` caps it; on cap the event is **discarded and destinations may be out of sync**; `drainQueueAttempts` bounds shutdown drain | [Gerrit replication config.md](https://gerrit.googlesource.com/plugins/replication/+doc/master/src/main/resources/Documentation/config.md) |
| **GitLab push mirroring** | async, **push-triggered** (≈5 min, ~1 min if "only protected branches") | mirror row shows a red **error** tag with the message as hover text; "Keep divergent refs" marks a diverging update **failed** | [GitLab push mirror](https://docs.gitlab.com/user/project/repository/mirror/push/), [troubleshooting](https://docs.gitlab.com/user/project/repository/mirror/troubleshooting/) |
| **Gitea/Forgejo mirror** | async on an interval (default 8 h; 1.18+ "sync when new commits are pushed"); server enforces `mirror.MIN_INTERVAL` | error message shown in UI; Gitea is criticized for **over-aggressive retry + admin notification** on transient failures | [Gitea repo-mirror](https://docs.gitea.com/usage/repo-mirror), [go-gitea#21610](https://github.com/go-gitea/gitea/issues/21610) |

**Read across these:** everyone chose async (latency/availability), but each pairs
it with a *persisted queue*, *bounded retry*, and a *visible failure state*.
Gerrit is the cautionary tale — when retries exhaust, the event is silently
dropped and destinations drift; the mitigation is monitoring the queue, not
trusting the ack. Tillandsias currently has the drop without the visibility.

### 3.3 Older/lighter idioms

- `git request-pull` — generates a human-readable "please pull" summary; relay by
  social protocol, not automation. Not a durability mechanism, but the honest
  baseline: the requester *knows* whether the pull happened.
- Gitolite/hook-era mirrors typically drive relay from a post-receive that pushes,
  and accept the same silent-failure risk unless paired with external monitoring —
  i.e. the pattern Tillandsias should move away from.

---

## 4. Protocol for the local hop

| Protocol | Auth | Encryption | Push safety | Verdict for an isolated container net |
|---|---|---|---|---|
| `git://` (git-daemon) | **none** | **none** | `receive-pack` off by default; docs warn *"there is NO authentication in the protocol … anybody can push anything, including removal of refs … solely meant for a closed LAN setting where everybody is friendly"* | OK for **read** on a trusted, isolated net; **never enable push** ([git-daemon(1)](https://git-scm.com/docs/git-daemon)) |
| Smart **HTTP** (`git-http-backend`) | via web server (basic/OAuth/mTLS) | TLS if configured | normal receive-pack + hooks | enterprise default; composes with the credential-helper story ([Pro Git — Smart HTTP](https://git-scm.com/book/en/v2/Git-on-the-Server-Smart-HTTP)) |
| **SSH** | keys/deploy keys | yes | normal | common for internal mirrors; GitLab notes deploy keys are "often more secure than password auth" ([GitLab mirroring](https://docs.gitlab.com/user/project/repository/mirror/)) |

Honest assessment for Tillandsias: on a genuinely isolated container network with
no cross-tenant reachability, `git://` for **fetch** is defensible and eliminates
all CA/credential env for the read path. But the relay/write semantics you care
about (auth, non-fast-forward denial, hooks, atomic) argue for the mirror to
**receive** forge pushes over smart-HTTP or SSH, even internally — `git://` gives
you no `receive.denyNonFastForwards` enforcement against a compromised forge
(anyone on the net can delete refs). Contested point: some teams run git:// push
on air-gapped nets for speed; the git docs explicitly scope that to "friendly"
LANs only.

---

## 5. Distributed concurrent teams — conventions that scale

| Practice | Why | Source |
|---|---|---|
| **Protected / fast-forward-only integration branches** | prevents force-push history loss and diverged mirrors; "Keep divergent refs" preserves ff-only semantics | [GitLab mirroring](https://docs.gitlab.com/user/project/repository/mirror/) |
| **Server-side hooks for policy** (pre-receive/update), not client trust | client-side hooks are advisory and bypassable; enforce on the server | [githooks(5)](https://git-scm.com/docs/githooks) |
| **Config in versioned includes, not env** | `include.path` (unconditional) and `includeIf.<cond>.path` (conditional: `gitdir:`, `onbranch:`, `hasconfig:remote.*.url:`) load config from files under version control, evaluated deterministically — instead of `GIT_CONFIG_GLOBAL`/env that differs per host and per shell | [git-config(1)](https://git-scm.com/docs/git-config) |

### Why includes beat the env mesh (directly addresses the drift pain)

- `includeIf "gitdir:…"` selects config by *repo location* — one committed file
  can express "forge repos use the local mirror + this CA," evaluated the same on
  podman, the macOS VM, and WSL2. Env vars are set by whatever launched the
  process and drift silently across those three launchers.
- Includes are **files in git**: reviewable, diffable, provenance-tracked. Env
  injection is invisible until something breaks. This is the "defaults over
  configuration" principle applied to config *delivery*: put the config where Git
  looks by default (a config file it includes), not in an out-of-band channel.
- Trailing-slash gotcha: `gitdir:~/work/` matches subdirs; `~/work` matches only
  the exact path. ([git-config(1)](https://git-scm.com/docs/git-config))

---

## 6. Recommendations for Tillandsias (per-mechanism disposition)

| # | Pain point today | Recommended default | Rationale / source |
|---|---|---|---|
| R1 | post-receive relay acks then may lose the upstream push | **Move relay off post-receive.** Either (a) synchronous: relay inside pre-receive / a proxying receive-pack so the forge push fails when GitHub does; or (b) async **with a durable, monitored queue** (persisted events, bounded retry+backoff, visible `failed` state). Never ack-and-forget. | post-receive "does not affect the outcome" ([githooks(5)](https://git-scm.com/docs/githooks)); Gerrit's silent drop-on-max-retries is the warning ([Gerrit config.md](https://gerrit.googlesource.com/plugins/replication/+doc/master/src/main/resources/Documentation/config.md)) |
| R2 | partial/half relays | Relay to GitHub with **`git push --atomic`** and explicit refspecs | all-or-nothing; no partial upstream state ([git-push(1)](https://git-scm.com/docs/git-push)) |
| R3 | mirror could wipe upstream refs | **Never `+refs/*:refs/*` on the write path.** Explicit non-force refspecs; set `receive.denyNonFastForwards=true` and `receive.fsckObjects=true` on the mirror | mirror push deletes absent refs ([git-clone(1)](https://git-scm.com/docs/git-clone)); integrity + rewind protection ([Pro Git 8.1](https://git-scm.com/book/en/v2/Customizing-Git-Git-Configuration)) |
| R4 | credentials injected into forge env | **Credential broker via the helper protocol** on the trusted side; mint **short-TTL GitHub App installation tokens** (1 h, repo-scoped); return `password_expiry_utc` | secret stays out of the sandbox ([gitcredentials(7)](https://git-scm.com/docs/gitcredentials), [GitHub App token](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app)) |
| R5 | config env mesh drifts across podman/VM/WSL2 | **Replace `GIT_CONFIG_GLOBAL`/`insteadOf`/`GIT_SSL_CAINFO` env with a committed include** selected by `includeIf gitdir:` | deterministic, versioned, host-agnostic ([git-config(1)](https://git-scm.com/docs/git-config)) |
| R6 | MITM proxy CA-trust env sprawl | Put `http.sslCAInfo` in the same versioned include, **or bake the CA into the image** so no runtime env is needed | fewest moving parts; defaults-over-config |
| R7 | `git://` for the local hop | Keep `git://` for **fetch on the isolated net** if desired (drops all CA/cred env for reads); **do not allow push over it** — receive pushes over smart-HTTP/SSH so denyNonFastForwards/hooks/auth actually apply | git-daemon has no auth and can't stop ref deletion ([git-daemon(1)](https://git-scm.com/docs/git-daemon)) |
| R8 | no visibility when relay fails | Expose relay **queue depth, last-error, and a `failed` state** to the litmus/monitor layer; treat a stuck queue as a P0, mirroring GitLab's error-tag surfacing | [GitLab troubleshooting](https://docs.gitlab.com/user/project/repository/mirror/troubleshooting/) |

### Contested / caveats
- **Sync vs async relay** is a genuine tradeoff: synchronous gives correct
  back-pressure (forge feels GitHub outages) but couples forge latency to GitHub;
  async decouples but *requires* the visible queue to be safe. Every incumbent
  chose async — but none of them ack-and-forget. Pick async **only** with R8.
- **git:// on internal nets** is defended by some teams for speed but the git docs
  restrict push to "friendly" LANs; for a sandbox that runs *untrusted agent code*
  the forge side is not fully "friendly," so treat write paths as hostile.
