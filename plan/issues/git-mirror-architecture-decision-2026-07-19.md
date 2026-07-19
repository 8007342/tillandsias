# Git transparent mirror — architecture decision + hack obsolescence plan (2026-07-19)

- **Status**: research COMPLETE — decision recorded, implementation packets filed
- **Owner host**: linux (plan writes), any (implementation)
- **Branch**: linux-next
- **Specs**: git-mirror-service, tillandsias-vault, forge-offline
- **Supersedes the open research question in**: order 322 (rung E, "research-first"),
  order 330 (build-vs-adopt evaluation of off-the-shelf mirrors)
- **Operator authorization**: Tlatoani, 2026-07-19 — full re-architecture authorized.
  This document declines that authorization on evidence; see Decision 1.

## Why this document exists

The mirror had accreted ~22 distinct compensating mechanisms across the launcher,
the forge entrypoints, and the mirror container. Agents could no longer reliably
push. The operator asked for official documentation and industry standard practice
to be consulted before any further hacking, and authorized changing the architecture
if the research demanded it.

Two independent investigations ran: a full as-built audit of this repository, and a
documentation/industry survey with empirical reproduction against git 2.55.0.

## Decision 1 — KEEP the synchronous pre-receive relay. Do NOT re-architect.

The current shape — agents push to a bare local mirror; a `pre-receive` hook relays
the exact proposed ref transaction to GitHub with `git push --atomic`; the hook
returns non-zero if GitHub refuses, so mirror refs advance only on upstream
acceptance — is **correct and is documented industry practice**, not a homegrown
invention.

- GitLab documents this exact pattern under *Bidirectional mirroring*, including the
  `unset GIT_QUARANTINE_PATH` step, linking git's own quarantine documentation.
  <https://docs.gitlab.com/user/project/repository/mirror/bidirectional/>
- Our implementation is **stronger than GitLab's published sample**: theirs proxies
  one ref at a time and explicitly warns "it is possible for some refs to succeed,
  and others to fail." Ours relays the whole transaction with `--atomic`.

### Build-vs-adopt: adopting an off-the-shelf mirror would be a REGRESSION

This closes order 330. No off-the-shelf tool performs *synchronous* push-through
mirroring where the proxy holds the upstream credential.

| Candidate | Verdict | Why |
| --- | --- | --- |
| Gitea / Forgejo push mirror | Reject | **Asynchronous** — client push succeeds before GitHub sees it. Also: a repo cannot be both pull mirror and push target; writes to `IsMirror` repos are hard-blocked 403 (source-only behaviour, undocumented). Docs warn the push "will force push … will overwrite any changes in the remote repository". |
| GitLab push mirror | Reject | Asynchronous, same false-success class. |
| Gerrit replication plugin | Reject | Push-only, review-gated `refs/for/*`; poor fit for autonomous agents. |
| GitHub repository cache | Reject | GHES-only, no github.com equivalent; read-only; requires a GitHub credential inside every container — violates our core constraint. |
| gitolite `mirror.redirectOK` | Reject | Requires the master to *be* gitolite; forwards user identity upstream — the opposite of credential isolation. |
| git-cache-http-server / google/goblet | Reject | Read-only; forward the *client's* credentials upstream. goblet is archived; git-cache-http-server's last real commit is 2020. |
| Artifactory VCS / Nexus | Reject | Tarball-over-REST; no clone/fetch/push. Nexus does not support git as a format. |

Every tool that holds upstream credentials server-side is asynchronous. Every tool
that is synchronous forwards client credentials. We require both server-held
credentials *and* synchronous durability, so we must own the relay. **The wheel does
not exist.**

**Therefore the reliability failures are NOT architectural.** They are concentrated
in (a) the credential lifecycle and (b) the serving layer. Those are cheap to fix.

## Decision 2 — the P0 defect was a missing refspec, now fixed

`git fetch <url>` with no refspec **ignores `remote.origin.fetch` entirely and
updates ZERO refs** (it writes only `FETCH_HEAD`), while reporting success. Both
relay fetch sites did this from commit `b49b7776` (order 413), which deleted the
refspecs order 369 had added.

Impact: the mirror's exported `refs/heads/*` could never advance, so an agent's
`fetch → rebase → retry` loop read identical stale state forever. **Agents livelock
rather than fail.** The reconcile additionally logged *"Mirror is now up to date."* —
the same false-success class order 318 was created to eliminate, reintroduced one
layer down.

Fixed in `a9eed3e8`, split by phase so each fetch touches only what it may:

- **pre-push staleness guard** fetches ONLY `+refs/heads/*:refs/remotes/origin/*`.
  Advancing an exported head *before* the relay decision would pre-empt the rejection
  path, so a genuinely stale push would no longer be refused and the reconcile that
  teaches the agent to rebase would never fire.
- **post-failure reconcile** fetches non-forced `refs/heads/*:refs/heads/*` and
  `refs/tags/*:refs/tags/*` plus tracking refs. Non-forced (no leading `+`) is what
  keeps order 301 fixed: a stale upstream SHA cannot clobber a newer just-received
  head, because that is a non-fast-forward and git refuses it. Stranded heads survive.

Evidence: `scripts/test-git-mirror-relay-verified-ack.sh` case 4 RED → GREEN;
`litmus:git-mirror-fetch-reconcile` and `litmus:git-mirror-relay-verified-ack`
RED → GREEN; instant pre-build suite 146/149 (3 failures pre-existing and unrelated).

### Quarantine: the trap that cost a full agent-session

Per `git-receive-pack`, incoming objects sit in a quarantine directory and the
pre-receive hook "MUST NOT update any refs to point to quarantined objects." The
hook's child `git` inherits `GIT_QUARANTINE_PATH`, so any ref-writing fetch fails
with `ref updates forbidden inside quarantine environment`.

The escape is to unset it **for the child process only**, keeping
`GIT_OBJECT_DIRECTORY` so quarantined objects remain readable:

```sh
env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES git fetch …
```

Commit `1a3548d2` **removed** this escape, reasoning in-comment that inheriting
quarantine was "fine". It is not. That deletion is why the accompanying
`merge-base --is-ancestor` reconcile could never land its `update-ref` calls, and the
authoring agent then iterated for hours on ancestry logic that was never broken. Its
written conclusion — *"cannot use `git fetch` with any refspec to update local refs"* —
is **falsified** by the now-passing fixture.

**Invariant for all future work: the quarantine escape is load-bearing. Never remove
it. It is pinned by two litmus greps; treat a change that requires editing those
greps as a red flag.**

## Decision 3 — fix the credential lifecycle (this is the live systemic blocker)

The mirror mints a Vault AppRole token at container start with ~1h TTL and reads the
GitHub token into a shell variable. **Roughly one hour into every forge session the
mirror silently loses Vault access**, `vault-cli read secret/github/token` returns
empty, and every push dies with `pre-receive hook declined` — with a misleading
"run GitHub Login" diagnostic. This is deterministic, on a one-hour fuse from
container start, and hits every agent on every host regardless of checkout.

Order 414 landed a renewer, but **the running mirror serves image `v0.3.260717.1`,
built before 414** — `vault-cli lookup-self` returns `unknown subcommand` in the live
container. This is the **third** recurrence of "code fix lands, running container
serves the old image" (301→302, 369→384, 414→now).

Two changes, both documented practice:

1. **Stop reading the token once at startup. Register a `credential.helper` instead.**
   Git invokes the helper per credential request, so "token expired at startup"
   becomes an unrepresentable state. Note `credential.helper` is *additive* — you
   must reset inherited helpers with an empty value first (see order 319 rung B).
2. **Use Vault Agent auto-auth** rather than a periodic token. HashiCorp recommends
   Agent for long-running processes; a periodic token is eventually defeated by
   `max_ttl` (24h). <https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent>

Longer term, prefer a **GitHub App installation token** over a PAT: scoped by
`repository_ids` and `permissions`, 1h expiry, decoupled from user identity and
consuming no licensed seat. GitHub: "for long-lived integrations, you should use a
GitHub App." This is already filed as order 390.

## Decision 4 — close the two unauthenticated write paths (SECURITY)

The mirror currently exposes **two** paths that accept anonymous pushes:

1. `git daemon --export-all --enable=receive-pack` on 9418. Git's documentation is
   blunt: receive-pack over the daemon "is disabled by default, as there is *no*
   authentication in the protocol (in other words, anybody can push anything into the
   repository, including removal of refs). This is solely meant for a closed LAN
   setting where everybody is friendly." Pro Git adds that `git://` has "absolutely no
   authentication or cryptography."
2. `lighttpd` + `git-http-backend` with `http.receivepack true` and **no auth module
   loaded** — which git documents as enabling push "for all users, including anonymous
   users."

Path 2 is additionally **dead**: nothing in the launcher or forge ever uses HTTP; all
transport is `git://`. `lib-common.sh` nonetheless advertises `tillandsias-git:8080`
to the user.

Target: drop the daemon, serve authenticated smart HTTP only, and give each container
a distinct credential so pushes are attributable. Pro Git recommends smart HTTP
precisely because it "can be set up to both serve anonymously like the `git://`
protocol, and can also be pushed over with authentication and encryption like the SSH
protocol." This is order 322 (rung E) — its research gate is now satisfied by this
document.

## Decision 5 — decouple policy from transport

`pre-receive` performs ledger-YAML validation *and* the upstream relay. The YAML gate
is unspecified (`spec.md` R3 says only "validate local policy"), has a known
`Psych::DisallowedClass` Date bug, and `tillandsias-policy` is not installed in the
git image — so every push falls to the buggy ruby path. Agents commit
`plan/index.yaml` on nearly every cycle, so this gate sits directly across the hot
path. Separate the concerns.

## Hack obsolescence register

Load-bearing, keep: explicit push refspecs (never `--mirror`), bulk-delete guard,
`safe.directory` globs, forge-uid chown, quarantine escape, empty credential helper.

Removable now:

| Hack | Location | Why obsolete |
| --- | --- | --- |
| lighttpd + git-http-backend | `images/git/lighttpd.conf`, `entrypoint.sh` | Orphaned — zero consumers; all transport is `git://`. Also an anonymous write path. |
| GitHub token injected into forge | `main.rs` (`HOMEBREW_GITHUB_API_TOKEN`) | Contradicts `forge-offline` spec ("forge containers carry ZERO credentials") and `git-mirror-service` R5. Only brew consumes it. |
| Dual network aliases (`git-service` + `tillandsias-git`) | `main.rs` | Papers over a naming disagreement rather than fixing it. Pick one, fix call sites. |
| `curl -k` in vault-cli | `images/git/vault-cli.sh` (6 sites) | Disables TLS verification despite a commit explicitly requiring CA-authenticated HTTPS, and despite `CURL_CA_BUNDLE` being passed. |

Blocked on the fail-loud work below: the `.git` facade, `notmpcopyup` mask, and
`insteadOf` interception all remain necessary under the current topology.

## The cross-cutting defect: silent degradation

The recurring theme across all filed mirror issues is **not that things break — it is
that they break silently while reporting success**. Three subsystems (mirror redirect,
gitdir facade, forge index) all degrade to no-ops when a single host `git` shell-out
fails, with the failure swallowed by `?`, `.ok()?`, or `|| true`. Verified
consequence: 3 of 5 live generated forge gitconfigs carry **no mirror redirect at
all**, so those projects' pushes target github.com directly and fail with
`could not read Username`.

Any change in this area must **fail loud**. A silent no-op that logs success is worse
than a crash, because it converts a fixable error into an agent livelock — which is
exactly what consumed a full agent-session on 2026-07-19.

## Follow-on packets filed

See `plan/index.yaml` orders filed alongside this document, and:

- `git-mirror-relay-reconcile-debug-findings-2026-07-19.md` (prior-agent research;
  conclusion superseded by Decision 2, methodology retained)
- Order 384 — deploy: rebuild `tillandsias-git` image (blocks Decision 3 taking effect)
- Order 319 rung B — vault-backed credential helper (Decision 3)
- Order 322 rung E — authenticated smart HTTP (Decision 4; research gate now satisfied)
- Order 330 — build-vs-adopt (CLOSED by Decision 1)

## Sources

- git-receive-pack (quarantine): <https://git-scm.com/docs/git-receive-pack>
- git-clone / git-remote (`--mirror` semantics): <https://git-scm.com/docs/git-clone>
- git-push (`remote.<name>.mirror` deletes refs): <https://git-scm.com/docs/git-push>
- git-daemon (receive-pack has no authentication): <https://git-scm.com/docs/git-daemon>
- Pro Git, server protocols: <https://git-scm.com/book/en/v2/Git-on-the-Server-The-Protocols>
- GitLab bidirectional mirroring: <https://docs.gitlab.com/user/project/repository/mirror/bidirectional/>
- Vault tokens / Vault Agent: <https://developer.hashicorp.com/vault/docs/concepts/tokens>,
  <https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent>
- GitHub App installation auth: <https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation>
- Gitea / Forgejo repo mirror: <https://docs.gitea.com/usage/repo-mirror>, <https://forgejo.org/docs/v15.0/user/repo-mirror/>
</content>
</invoke>
