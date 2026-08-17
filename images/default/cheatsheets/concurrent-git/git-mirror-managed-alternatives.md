---
tags: [git, mirror, replication, build-vs-adopt, observability, forge, concurrent]
languages: [bash]
since: 2026-08-16
last_verified: 2026-08-16
sources:
  - https://docs.gitlab.com/user/project/repository/mirror/bidirectional/
  - https://docs.gitlab.com/user/project/repository/mirror/push/
  - https://docs.gitea.com/usage/repo-mirror
  - https://forgejo.org/docs/latest/user/repo-mirror/
  - https://gerrit.googlesource.com/plugins/replication/+doc/master/src/main/resources/Documentation/config.md
  - https://docs.github.com/en/enterprise-server@3.13/admin/enterprise-management/caching-repositories/about-repository-caching
  - https://gitolite.com/gitolite/mirroring.html
  - https://github.com/google/goblet
  - https://git-scm.com/docs/git-push
  - https://git-scm.com/docs/githooks
authority: high
status: current
tier: bundled
summary_generated_by: "claude-fable-5 order-330 distillation of the ratified order-315/2026-07-19 decision"
bundled_into_image: true
committed_for_project: true
---
# Git Mirror — Managed Alternatives and Observability Requirements (order 330)

Two questions, one answered and one open.

**Answered (do not re-litigate):** should Tillandsias adopt an off-the-shelf
mirror container instead of its bespoke synchronous relay? No. That evaluation
was completed and ratified in
`plan/issues/git-mirror-architecture-decision-2026-07-19.md` ("Decision 1 — KEEP
the synchronous pre-receive relay"), which declares itself to supersede order
330's build-vs-adopt half. This cheatsheet is the distillation that decision
was missing, not a fresh investigation.

**Open (operator-owned):** the adopt/keep call is The Tlatoāni's to ratify, and
the observability requirements below are the part still to be implemented.

## Why the wheel does not exist

The requirement is unusual and the two halves are, in every shipping tool,
mutually exclusive:

1. **Server-held upstream credentials** — the proxy holds the GitHub token;
   no container ever sees it.
2. **Synchronous durability** — a client push succeeds only if GitHub already
   accepted it, so an agent that saw success cannot later discover its work is
   gone.

| Candidate | Verdict | Why |
| --- | --- | --- |
| Gitea / Forgejo push mirror | Reject | **Asynchronous** — the client's push succeeds before GitHub sees it. A repo also cannot be both pull mirror and push target: writes to `IsMirror` repos are hard-blocked 403 (undocumented source-only behaviour). Docs warn the push "will force push … will overwrite any changes in the remote repository". |
| GitLab push mirror | Reject | Asynchronous; same false-success class. |
| Gerrit replication plugin | Reject | Push-only and review-gated (`refs/for/*`) — a poor fit for autonomous agents. |
| GitHub repository cache | Reject | GHES-only with no github.com equivalent; read-only; requires a GitHub credential inside every container, violating requirement 1. |
| gitolite `mirror.redirectOK` | Reject | Requires the master to *be* gitolite, and forwards the user's identity upstream — the opposite of credential isolation. |
| git-cache-http-server / google/goblet | Reject | Read-only, and both forward the *client's* credentials upstream. goblet is archived; git-cache-http-server's last substantive commit is 2020. |
| Artifactory VCS / Nexus | Reject | Tarball-over-REST; no clone/fetch/push. Nexus has no git format at all. |

**The rule the table encodes:** every tool that holds upstream credentials
server-side is asynchronous, and every synchronous tool forwards the client's
credentials. We require both properties, so we own the relay.

The bespoke design is not a homegrown oddity — GitLab documents this exact
pattern under *Bidirectional mirroring*, including the `unset
GIT_QUARANTINE_PATH` step. Our implementation is **stronger** than GitLab's
published sample: theirs proxies one ref at a time and warns that "it is
possible for some refs to succeed, and others to fail", while ours relays the
whole transaction with `git push --atomic`.

**Corollary worth keeping:** the mirror's reliability failures have never been
architectural. They concentrate in the credential lifecycle and the serving
layer — both cheap to fix, and both where the observability below points.

## Migration ladder (if the decision is ever revisited)

Recorded so a future revisit starts from evidence rather than from scratch.
Adopting any candidate above requires, in order: (1) accept asynchronous
acknowledgement — i.e. delete the durability guarantee agents currently rely
on, or re-add it as a second mechanism outside the adopted tool; (2) move the
upstream credential to wherever that tool keeps it, and re-audit which
containers can reach it; (3) re-express the order-316 policy gate as that
tool's hook surface; (4) re-home the per-project mirror identity (order
606-bvnp D13) onto the tool's naming model. Reverse migration is comparatively
cheap: the bespoke relay is a bare repo plus a `pre-receive` hook, so a
rollback is "point the daemon back at the bare repo".

## Observability requirements (the open half)

The mirror is a critical backbone with no runtime monitoring: nobody can
currently answer "is the relay keeping up?" without reading logs. These are
stated as testable claims so each can be pinned by a litmus rather than
inspected by eye.

1. **Relay queue depth** — the number of ref transactions accepted by the
   mirror but not yet acknowledged by upstream is observable at any instant.
   With a synchronous relay this is normally 0 or 1; a persistently non-zero
   depth is the signal that the relay has begun buffering, which the design
   says cannot happen.
2. **Last successful relay per ref** — for every exported ref, the timestamp of
   the last upstream-accepted transaction. Staleness per ref, not per repo:
   a repo-level "last push" hides one branch that stopped advancing.
3. **Per-ref divergence (mirror vs upstream)** — for every exported ref,
   whether the mirror's OID equals upstream's, and since when if not.
   Divergence is expected transiently and pathological if sustained.
4. **Ack latency** — the distribution (not just the mean) of the interval
   between accepting a client push and upstream acknowledging it. The tail is
   what agents experience as a hang.
5. **Pre-receive rejects** — a counter per rejection reason (non-fast-forward,
   deletion refused, fsck failure, policy gate), because "rejects went up" is
   only actionable with the reason attached.
6. **Credential-refresh failures** — a counter of upstream authentication
   failures distinguished from network failures, since the two have different
   operators and different fixes. Order 756-2jnj is the live example: a 403 on
   the mirror's credential was indistinguishable from reachability until the
   verdict ref was published.

**Transport:** these ride the control wire per order 323, not a new TCP
endpoint — the same reasoning that put guest container metrics on the control
wire in order 333 (a host that cannot reach a guest TCP port cannot read
guest-only facts).

**Anti-requirement:** none of these may be satisfied by a fabricated healthy
value when collection fails. A collection failure is reported as an error with
the value absent (`spec:observability-metrics`), because a metric that reads
healthy when it cannot be measured is worse than a missing one.

## Provenance

- Ratified decision + rejection table:
  `plan/issues/git-mirror-architecture-decision-2026-07-19.md`
- Packet: order 330 (`git-mirror-observability-and-managed-alternatives`),
  declared audit input to order 315; multi-cycle, and the adopt/keep decision
  is The Tlatoāni's.
- Siblings: `cheatsheets/concurrent-git/git-mirror-enterprise-practices.md`
  (order-315 research), `cheatsheets/concurrent-git/git-mirror-architecture-audit.md`
