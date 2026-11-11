# Rubric — judge 1 (written before reading any blind design or surveying the current implementation)

Written 2026-11-11 from the coordinator's brief and the product promise only:
"a near-zero overhead system tray icon that launches a little regional cloud in
podman containers". Shape follows plan/issues/observatorium-blind-design-2026-11-09/
(method.md section 3, rubric.md). Nothing under designer-*/, security-design/,
events-design/ or blackbox-audit/ had been opened when this file was written; only
directory listings and the prior exercise's method/rubric/comparison had been read.

## Scoring rules

- Scale per row: 0 absent or wrong, 1 named but not mechanised, 2 partial mechanism,
  3 mechanism with a stated failure mode, 4 mechanism that is verifiable (a reader
  could write the failing check from the text / the code has the check).
- X = blind design AS REIFIED (reified.md is the scored text; design docs are
  evidence for what the reification kept). Y = current Tillandsias (specs + code).
- Each area is scored on "design quality" rows. "Implemented-ness" is ONE separate
  row per area (0 paper, 1 spec only, 2 code exists unproven, 3 runs on one
  platform, 4 runs and is gated on all claimed platforms) and is totalled
  separately, never added into the design total. X is paper by construction, so its
  implemented-ness is 0 unless the reification points at existing code it reuses
  unchanged (then it inherits no credit either: reuse is Y's credit).
- CONTAMINATION RULE. Every blind agent saw the injected CLAUDE.md, the memory
  index and the skill list. A row where X agrees with Y on an item the designer
  marked [C] or disclosed as seen is scored for X as "n.i." (non-independent): X
  receives the SAME score as Y on that row minus nothing and plus nothing, and the
  row is excluded from the X-vs-Y delta and from any "independent confirmation"
  claim. Only (a) independent agreement on undisclosed items and (b) disagreement
  count as information. An X idea that merely restates a leaked operator ruling
  earns no independent credit even if it is good.
- Per-platform rule. An obligation "holds" only if it holds independently on Linux,
  macOS and Windows. A design that states one mechanism and asserts it for all
  three scores at most 2 on the per-platform row; 3-4 needs the per-platform
  substrate named and the failure mode per platform.
- Where both X and Y score <=1 on a row, the row is a candidate SHARED WEAKNESS
  (Knight & Leveson: suspect the shared input, here the product promise and the
  leaked index).
- One judge's scores. No averaging with judge 2 here.

## Areas and rows

### T. Tray and process model (designer-a, designer-b vs current)
- T1 Near-zero overhead is a number: idle CPU/RSS/wakeups budget stated, measured,
  and guarded (what happens when exceeded).
- T2 Tray does one thing: process model, what runs when nothing is launched, no
  polling without cause (events over polls; operator ruling on cadence is leaked,
  check contamination).
- T3 Never blocks / never freezes: menu open path is bounded; long work is off the
  UI thread; visible single status line.
- T4 Lifecycle: install, first run, launch, stop, crash, upgrade, uninstall;
  idempotent reset; what survives.
- T5 End-user surface: no prompts, internals invisible, one curated message.
- T6 Per-platform holding of T1-T5 (Linux/macOS/Windows substrates named).

### R. Regional cloud: topology and lifecycle (designer-a, designer-b vs current)
- R1 Service inventory: each service named with what it earns; a count; a service
  that earns nothing is a defect.
- R2 Isolation: forge has no direct egress/credentials; enclave network shape;
  what a compromised forge can reach.
- R3 Start/stop ordering, health, degraded modes, retry/backoff, readiness seen by
  the user and by agents.
- R4 Storage and state: single root, what is ephemeral vs durable, disk awareness,
  rebuildability ("ephemeral things need no wipe permission").
- R5 Resource floor: runs on a low-end host; lazy start; idle cost of the cloud.
- R6 Per-platform substrate (rootless podman / VZ VM / WSL2) and what differs.

### S. Security and credential hygiene (security-design vs current; a/b where they touch it)
- S1 Threat model is explicit: actors, assets, trust boundaries, what is out of
  scope.
- S2 Credential flow end to end: where each secret is born, stored, transits,
  who can read it, how it is revoked (vault, OS keyring, role identities, CA,
  git mirror, host push, provider logins).
- S3 No plaintext at rest; fail-closed gates; lost-credential path is wipe and
  re-login (leaked ruling: check contamination).
- S4 Least privilege per service identity; blast radius of one stolen identity.
- S5 Operator-consent boundary: cost-bearing or identity-bearing outward calls
  need verified approval.
- S6 Auditable: a checklist a third party can run read-only and get pass/fail.
- S7 Per-platform holding (keyring/biometric/secure store per OS).

### P. Supply-chain provenance (security-design vs current)
- P1 Images/binaries: pinned, digests, signatures, SBOM, release verification
  by the installer.
- P2 Cheatsheets: provenance annotations exist, are machine-checked, and staleness
  is detectable.
- P3 Local models: registry with source, digest, licence, size; fetch refuses
  unknown or unlicensed.
- P4 Per-project licence acceptances: who accepted, what text, when, where the
  record lives, how a fetch is refused without it.
- P5 Agent-fetched dependencies (crates/npm/pip through the proxy): what is
  recorded, what is blocked.
- P6 Per-platform holding.

### E. Events, logs, observability for forge agents (events-design vs current)
- E1 Event model: schema, versioning, ordering, identity/origin on every record.
- E2 Agent consumption: how a forge agent asks "what happened / is it ready /
  why did it fail / when may I retry" without scraping; push vs poll.
- E3 Visibility scoping: own forge + children + curated global; no siblings.
- E4 Privacy and retention: session-only/ephemeral, no secrets or PII in events,
  redaction mechanism.
- E5 Cost: bounded buffers, backpressure, near-zero idle cost.
- E6 User-facing curation: one status line, curated messages, distinct from raw
  logs.
- E7 Per-platform holding (transport through VM/WSL boundaries).

### X. Cross-cutting (scored once per designer and once for current)
- C1 Simplicity / earned complexity: every component justified by an obligation;
  things removed; no speculative machinery.
- C2 Language direction: Lua/Rust/Go, minimal bash/python; a migration path, not
  a rewrite wish.
- C3 Obligation discipline: obligations stated before design, each traceable to a
  mechanism and a check that could fail.
- C4 Honesty: unknowns logged as questions with assumptions and consequences;
  reification changed the design where answers contradicted it.
- C5 Falsifiability: measures/exit criteria that would fail on a wrong
  implementation.

### I. Implemented-ness (separate total)
One row per area T, R, S, P, E: 0-4 as defined above, for Y; X is recorded as 0
with a note of which existing mechanisms the reification assumes.

## Maxima
T 24, R 24, S 28, P 24, E 28, cross-cutting 20 per subject. Design total per
single-domain comparison = area max (+20 cross-cutting). Implemented-ness /20,
reported apart.

## What I will report regardless of scores
- For every row where X and Y differ: who is right, with evidence by symbol or
  spec name.
- Every row scored n.i., listed, so the reader can see how much of the apparent
  agreement is contamination.
- Rows where my rubric turned out to be wrong-shaped after reading (recorded as a
  rubric defect, not silently re-scored).
