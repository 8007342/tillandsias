# DECISION NEEDED (Tlatoāni): the Build counter's declared flow contradicts the version guard — one must yield

- Filed: 2026-08-23 (UTC) by windows host **yolanda** (loop cycle #6), as the
  ruling row **862-zhr2**. Unblocks 643-64bx criteria 1+3 (p1,
  fail-loud-diagnosis-milestone).
- Class: research/ + decision record. Related: methodology/versioning.yaml,
  scripts/hooks/pre-push-version-guard.sh, 602-tfzg (deadlock family),
  702-griq (content addressing), 599-w5jd (push CI removed), 648-772y
  (version-skew signal), the 2026-08-10 windows partial on 643-64bx.

## The contradiction, stated once

methodology/versioning.yaml declares the Build segment: "Automatic on every
local build (./build.sh), manual bump at merge … At merge time, conflicts
resolve via LUB (max wins)" — i.e. the counter is DESIGNED to move on every
host and FLOW through branch merges. scripts/hooks/pre-push-version-guard.sh
forbids any VERSION change from pushing to a non-main branch — i.e. the flow
the methodology declares is exactly what the guard prevents. Neither is
wrong alone: the guard protects "main's VERSION is the release identity"
(643-64bx's own notes call it load-bearing); the methodology's counter was
added because a stale VERSION at release was a real defect. Together they
manufacture the 602-tfzg deadlock on the most common command in the project,
and every host's practical resolution for two weeks has been "revert the six
files every time" — the LUB-merge design is de facto dead code.

Already done (leave in place under either ruling): criterion 2's
branch-aware advice (2026-08-10, pinned in litmus:versioning-shape), and
`./build.sh --check` deliberately never bumps (build.sh:1155) — a
verification gate must not mutate the tree under ANY ruling.

## Resolution A — the counter goes off tracked files (RECOMMENDED)

Tracked VERSION moves only at release (the release workflow already bumps
it: c51d58c7a). Local builds stamp an UNTRACKED counter (gitignored file or
target/-resident) and dev binaries self-label `<VERSION>+local.<stamp>` via
the existing build.rs WORKSPACE_VERSION plumbing.

- Why recommended: it removes the contradiction instead of managing it; the
  guard's invariant becomes trivially true (no tracked VERSION churn exists
  off-main); 702-griq content addressing already makes a binary self-label
  diverging from the tree harmless; and the practice is ALREADY this —
  every host reverts the bump, so the tracked counter has recorded nothing
  real since the guard landed.
- Blast radius, measured: three build.rs consumers (windows-tray reads
  workspace VERSION today; macos five CARGO_PKG_VERSION sites are open work
  either way — see the 643 audit note); the 648-772y skew warning compares
  build_version over the wire — under A it must compare the RELEASE half
  plus commit hash (already embedded) rather than the local stamp, which is
  a sharper signal anyway (two same-day local builds of different commits
  currently compare equal); litmus:versioning-shape + the ci-full-install
  prep fixture re-pin; methodology/versioning.yaml Build semantics rewritten
  ("local display stamp, untracked; release identity moves at release").

## Resolution B — the flow is affirmed, the guard learns the one legal shape

Keep the tracked counter; the guard allows exactly one non-main VERSION
diff shape: the mechanical counter bump (six known files, same-date build+1
or date-reset-to-1, nothing else in the diff), and coordinator merges
LUB-resolve as the methodology says.

- Why not recommended: divergence management returns (platform branches
  race the counter; the coordinator resolves conflicts the guard was built
  to prevent); the guard grows a diff-shape parser that must never
  false-negative (a smuggled change inside a "mechanical" bump is the
  attack the guard exists for); and it re-animates a flow no host has
  actually wanted in practice.
- Honest advantage: zero build.rs/skew-signal changes; versioning.yaml
  stands as written.

## What this cycle did NOT do, on purpose

No half-implementation of either resolution: two prior hosts measured the
release-path blast radius and declined to guess, and this host agrees —
under bar_raise_governance the call is The Tlatoāni's. 643-64bx is set
`pending` (its remaining criteria are un-startable without this ruling —
the 628-c7qd lesson: a fenced-off row must not present as ready to
selectors). When 862-zhr2 is ruled, 643-64bx reverts to ready with the
chosen resolution named in one set-field.
