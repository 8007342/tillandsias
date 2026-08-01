# Operator vision: an AI-powered cloud region with a frozen control plane (2026-07-31)

Classification: `research/` — long-range vision context, recorded verbatim-adjacent
so future technical decisions can be checked against it rather than against
someone's memory of it.

Stated by The Tlatoāni, 2026-07-31, while approving the SSH transport decision for
order 322. The operator explicitly asked that this be carried as CONTEXT on work
packets: *"the long term goal, even though vague now, will be important as we make
technical decisions going forward."* It is deliberately recorded as VISION, not as
committed scope — nothing here is authorized work, and packets that cite it must
still carry their own exit criteria.

## The headline user story

A non-technical user logs a Tillandsias into an old computer, plugs it next to a
router, and walks away. No screen, no further interaction.

Later, from a project open on any laptop, they prompt an agent:

> host myproject.com

The agent finds a Tillandsias with **24/7 uptime affinity**, launches a web
container **there**, and the site is live. The user never learns what a container
is.

## Two hosting postures, deliberately different

- **`dev.mydomain.com` — enclave-hosted.** Inside the enclave, so local agents can
  manipulate it. This is the iteration surface.
- **`www.myproject.com` — production.** Hosted with **NO enclave and NO network
  access**, reached only through a native Cloudflare tunnel serving public HTTP,
  with a self-signed certificate for a domain the user owns. Transparently.

The asymmetry is the point: the thing agents can touch and the thing the public
can reach are not the same thing, and production is deliberately the more
constrained of the two.

## The framing that sets the bar

> *"We will provide an ai powered cloud region with a frozen control plane,
> transparently, freely, for non-tech users. So we must do EVERYTHING right from
> the get go, we cannot let users risk things they don't understand. We secure our
> agents, we secure our users, we empower them both, safely, in isolation,
> ephemeral, idempotent."*

Two consequences worth stating explicitly, because they change engineering
judgement:

1. **The user cannot assess risk.** A normal product can offload a security
   decision onto an informed operator. This one cannot — the target user does not
   know what they are being asked. So a default that is merely *documented* as
   risky is a defect, not a tradeoff. This is the same principle already load-
   bearing in the codebase ("a guard only an attentive agent honors is a
   suggestion, not a constraint"), applied to the human.
2. **"Frozen control plane" needs a definition before it can be built against.**
   Read literally it means the control plane is fixed and not user-mutable — which
   would be a strong safety property and would explain "cannot let users risk
   things they don't understand". It is NOT yet pinned anywhere. Flagged as the
   first thing to sharpen when this scope becomes real work.

## What is already filed, and what is not

Already in the ledger and directly serving this vision — these are the existing
consumers, not new work:

- 353 `enclave-service-catalog-milestone`
- 373 `web-share-release-milestone`
- 376 `catalog-multi-service-compose`
- 377 `cloudflare-login-implementation`
- 378 `warp-tunnel-ephemeral-public-serve`
- 379 `one-prompt-public-share-flow` — the closest existing analogue to
  "host myproject.com" as a single prompt
- 388 `cloudflare-tunnel-tls-in-proxy-router-research`

**Entirely unfiled as of 2026-07-31: the multi-node half.** Nothing in the ledger
covers node discovery, uptime affinity, cross-node authorization, or an identity
plane spanning hosts. Filed as 560–562 by this cycle.

## Why the SSH decision matters more than it looked

Order 322 asked a narrow question — how a forge pushes to its enclave mirror. The
operator chose SSH for a reason that reaches far past that packet: transparent SSH
credentials would let agents run inference and containers on **any** host with a
logged-in Tillandsias.

So 322 is no longer just a push transport. It is the first rung of the identity
plane this vision needs, which is why it is being implemented as an **SSH
certificate authority with short-lived certs and rotation** rather than
`authorized_keys` distribution. `authorized_keys` cannot rotate without touching
every node and cannot express "this principal, for this purpose, for ten minutes"
— both of which the mesh case requires.

Doing 322 as a CA now means the mesh work later issues DIFFERENT PRINCIPALS FROM
THE SAME CA rather than inventing a second scheme beside it. That is the whole
argument for paying the cost early.

## Open questions this vision raises but does not answer

Recorded so they are not silently decided by whoever implements first:

- **Authorization, not just authentication.** A signed cert proves *who*. It does
  not answer *what may this node ask that node to do*. A mesh where any logged-in
  node can launch containers anywhere is a lateral-movement surface, and the
  target user cannot evaluate it.
- **What "uptime affinity" is measured from**, and what happens when the chosen
  node disappears mid-serve.
- **Whether a production host with no network access can be updated at all**, and
  if so through what path — the constraint that makes it safe also makes it
  unreachable.
- **Trust bootstrapping**: how a brand-new headless box joins the mesh without the
  user performing a security ritual they do not understand.
- **Blast radius of the CA itself.** It becomes the highest-value secret in the
  system; its compromise is worse than any token's.

## How to use this file

Cite it as CONTEXT in packet outcomes when a decision is shaped by the long-range
goal. Do not cite it as authorization. When any part of it becomes real work, the
sharpened version belongs in `openspec/specs/` and this file becomes a pointer.

---

## Addendum 2026-07-31: authorization for non-technical users

Operator thinking-out-loud, recorded because it answers the hardest open question
above (authorization, not authentication) and because the framing is load-bearing
rather than decorative. Explicitly LONG-TERM: "just plan those for really long
term, there's lots we need to refine until then."

### The encrypted OK button

Not an identity device — an **approval** device. A hardware token (2FA/USB) the
user *touches*, producing a cryptographically verifiable "a human said go ahead".
Paired with a dialog and a short timeout: *"We're about to run a thing on your
host, it will have long lasting consequences…"*, wording to be designed per case.

Why this is the right shape for the stated user: it does not ask a non-technical
person to *understand* a risk, only to *be present* for it. That is the one thing
they can always do correctly.

Three properties worth pinning before anyone builds it:

1. **Bind the signature to the ACTION, not to the session.** The industry
   primitive here is WebAuthn/FIDO2, which signs a server-supplied challenge. Put
   a hash of the exact action description in that challenge, and the resulting
   signature proves the human approved *that specific text* — not merely that a
   human touched a token while something happened. Without this the obvious attack
   is bait-and-switch: show a benign dialog, perform a different action, reuse the
   assertion.
2. **A short timeout bounds replay**, and the assertion must be single-use.
3. **The headless case breaks the model and must be designed for.** The vision's
   own flagship node is an old computer by a router with nobody in front of it. A
   scheme that requires presence for every consequential action cannot run there.
   This is precisely where the skill tree earns its keep: unlocked capabilities are
   *pre-authorized* and need no touch; locked ones require presence. So the two
   ideas are one mechanism, not two features.

### The skill tree (a dashboard that is not a dashboard)

Operator: "dashboards are scary for users; dashboard is an internal word." The
user-facing surface is a videogame **skill tree** — a path toward "publish my app"
that guides through create-a-repo, create-assets, create-use-cases, while hiding
stories and epics. Users gain **XP** and **LEVEL UP** as their agents commit; enough
XP unlocks the next policies (e.g. unlocking the "release" skill lets them push web
apps).

**The load-bearing sentence, verbatim: XP is "user lingo for verifiable
constraints."** That is not flavour, and it should survive every future
simplification of this idea:

- It makes the skill tree a **projection of the policy graph**, not a veneer over
  it. An unlock is a real predicate over satisfied constraints, so the pretty
  surface and the security model cannot drift apart.
- It reuses machinery that already exists. `methodology/convergence.yaml` already
  defines `centicolon_residual` as "remaining named correctness obligations", and
  the Observatorium already computes and signs it. That residual is the natural XP
  denominator — progress toward zero residual IS levelling up.
- **It is the difference between a security model and an exploit.** If XP accrued
  from activity volume — commits, tasks, time — an agent could grind trivial
  commits to unlock `release` and deploy to production. Constraint-derived XP
  cannot be grinded, because the only way to earn it is to satisfy a check that
  something independent verifies. Any future proposal to make XP "feel more
  responsive" by rewarding activity is a privilege-escalation path and must be
  refused on those grounds.

### Where the two ideas join

Levelling up is a **capability grant**. Capability grants are exactly the class of
event that deserves human presence. So the natural composition is: XP accrues
automatically from verifiable constraints (no friction, invisible), and the moment
of *unlock* is where the encrypted OK button appears — once, with a clear
description of what the user is about to permit, bound into the signed challenge.

That yields low friction (touches are rare and meaningful) with a real audit trail
(every capability the system holds traces to a human assertion over a specific
text).

Still unrefined, and deliberately left open: XP legibility without exposing
epics/stories; what a *level* maps to in policy terms; whether levels can be lost
when a constraint regresses; and recovery when the token is lost — which for a
non-technical user is a likelier event than compromise.
