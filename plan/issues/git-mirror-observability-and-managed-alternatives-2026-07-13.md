# Git-mirror: dedicated observability + build-vs-adopt evaluation of off-the-shelf mirror containers

- Date: 2026-07-13
- Class: research (extensive; heavy-agent)
- Filed by: macos-osx-next meta-orchestration cycle 2026-07-13T22:43Z (operator directive: "look very closely at the git mirror … maybe even existing containers that provide out-of-the-box git mirror experiences we would 'just' configure … it's turning quite finicky even though it's a critical backbone")
- Related: order 315 (git-mirror architecture audit — this packet is a declared audit input), ladder rungs 318-322, order 316 (pre-receive subshell reject loss), cheatsheets/concurrent-git/git-mirror-architecture-audit.md, cheatsheets/concurrent-git/git-mirror-enterprise-practices.md
- Pickup: linux (heavy-agent, multi_cycle)

## Why this is not already covered

Order 315 + rungs A-E audit and **harden the bespoke mirror** (ack
semantics, credential helper, gitconfig injection, isolation, transport).
Two things remain unowned:

1. **Mirror-as-a-service observability.** Rung A specifies relay-state ack
   semantics, but nobody owns runtime monitoring of the mirror: relay queue
   depth, last-successful-relay timestamp per ref, per-ref divergence
   (mirror vs GitHub), ack latency, pre-receive rejects, credential-refresh
   failures. The defect history (false-success P1, ref-clobber 301/302,
   advisory-only YAML gate 316) shows failures are **silent** — exactly what
   monitoring exists to make loud. Metrics transport should reuse
   guest-container-metrics-over-control-wire-2026-07-13.md rather than
   invent a channel.

2. **Build-vs-adopt.** The bespoke mirror keeps consuming P1-class defect
   budget. Before investing rungs B-E, evaluate whether a maintained
   container gives the mirror experience out of the box and we "just"
   configure and wire it (vault credentials, proxy egress, pre-receive
   policy hook, control-wire metrics).

## Candidate set (starting point, not exhaustive)

Evaluate at minimum, on the axes below:

- **Forgejo / Gitea** (single container, built-in push+pull mirroring with
  interval + on-push relay, REST admin API, native Prometheus `/metrics`,
  post-receive hooks, aarch64 images, MIT/OSI)
- **GitLab CE** (full mirror semantics but multi-GB footprint — likely
  fails the 4 GiB guest budget; include as the calibration upper bound)
- **Soft Serve (charmbracelet)** (minimal SSH git server; check whether
  mirroring is native or would stay bespoke)
- **Plain `git` primitives done canonically** (bare repo + `git push
  --mirror` post-receive relay + `git-http-backend`/`git daemon` fetch
  side): i.e. keep bespoke but shrink it to boring, documented git — the
  enterprise-practices cheatsheet baseline
- Anything else surfaced with real adoption evidence (gerrit replication
  explicitly allowed to be dismissed on footprint)

## Evaluation axes (all rows scored, provenance links required)

1. Footprint in the 4 GiB guest (idle RSS, image size, aarch64 support)
2. Mirror semantics: synchronous on-push relay? relay-state exposed?
   (rung-A ack requirement must be satisfiable, not just hoped)
3. Credential handling: vault-injectable? short-TTL token rotation
   (rung B) without patching the product?
4. Policy hooks: can the order-316 YAML pre-receive gate run as a
   first-class hook that actually rejects?
5. Observability out of the box (Prometheus endpoint, relay logs/events)
6. Config surface vs DEFAULTS OVER CONFIGURATION (order-315 principle):
   how many knobs must we set and pin?
7. License + maintenance cadence
8. Migration cost from the current mirror (both directions — adopt and
   retreat)

## Deliverable

- `cheatsheets/concurrent-git/git-mirror-managed-alternatives.md`: scored
  matrix with retrieved-date provenance on every load-bearing claim, and a
  recommendation: `adopt <X>` or `keep-bespoke + rungs B-E`, with the
  observability requirements list attached to whichever wins.
- Recommendation is ratified through order 315's audit (this packet feeds
  it; The Tlatoāni owns the adopt/keep decision).

## Verifiable closure

- Matrix complete (no empty cells on the axes above for the candidate set);
- One named recommendation with a migration-ladder sketch;
- Mirror observability requirements enumerated as testable statements
  (each one phrased so a litmus can later pin it).
