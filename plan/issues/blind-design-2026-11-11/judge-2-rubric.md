# Rubric — judge 2 (written before reading any design, reified.md, answers.md, audit finding or implementation source)

Read before writing this file: the task brief, the prior protocol shape
(`plan/issues/observatorium-blind-design-2026-11-09/{method,rubric,comparison}.md`),
the directory listing, and `operator-questions.md` (one-line decisions only).
Nothing else.

## Scale

Every row is scored 0–4 **twice per side**:

- **D (design)**: does the design, as written, state a mechanism that would hold
  the property under the *real* constraints? 0 absent · 1 named only · 2 a
  mechanism, but naive about a named real constraint · 3 a mechanism that
  survives the constraints · 4 as 3 and it states how it fails and how that is
  detected.
- **I (implemented)**: is it running code today? 0 paper · 1 spec/stub only ·
  2 code exists, not wired or not on every platform it claims · 3 wired and
  exercised by a test that could fail · 4 as 3 and evidence from a live run.

Blind designs get I = 0 by construction; that is recorded but **never summed
into D**. Totals are reported as D-total and I-total separately. A typical
"X/Y" single number hides exactly the thing this exercise is for.

"Blind-reified" (X) is scored as the *best single blind design for that row
after reification* — but a row where the four blind designs contradict each
other without resolution is capped at 2 (a design that is really three designs
is not a mechanism).

## Contamination rule

Any element a blind agent marked `[C]`, or disclosed as derived from the
injected CLAUDE.md / memory index / skill list, earns **no agreement credit**:
for that row X is scored only on what the blind design adds beyond the
contaminated element. If nothing is added, X.D = "C" (excluded from the sum on
both sides, row reported separately). Undisclosed agreement that matches a
memory-index headline verbatim is treated as contaminated too (I list which).

## Adversarial checks applied to every row

Against blind: (n1) does it assume a capability the platform lacks (rootless
podman limits, no systemd user session, macOS VM boundary, WSL2 lifetime,
Silverblue immutability, no sudo)? (n2) does it assume a budget nobody
measured? (n3) does it assume an operator will answer prompts the product
promise forbids? (n4) does it trade a credential-at-rest for convenience?
(n5) does it invent a daemon the "near-zero" promise cannot afford?

Against current: (e1) is there a second mechanism doing the same job?
(e2) is the mechanism exercised only by its own fixture? (e3) is it in a
language the direction says to leave (bash/python), and how many lines?
(e4) does the spec claim more than the code does? (e5) does it exist to serve
the fleet's development process rather than the product promise?

## Areas and rows

### A. Product promise — "near-zero overhead system tray icon that launches a little regional cloud in podman containers" (7 rows)
- A1 Idle cost is *defined* (which processes, which unit) and *bounded by a number someone can measure*.
- A2 Idle cost is event-driven: no polling loop without a stated period and owner approval.
- A3 Launch path: one action from tray to a running forge; failure states are finite and each has one user-visible sentence.
- A4 "Little regional cloud" has a stated service inventory (what runs, why each exists, what stops when nothing is open).
- A5 Lifecycle idempotency: reset/reinstall/wipe is the baseline and converges; ephemeral things rebuild without ceremony.
- A6 Degradation when the tray host/indicator is absent, when the container runtime is absent, when disk is full.
- A7 End-user surface carries no power-user internals (installer silent, no prompts, internals invisible).

### B. Per-platform obligation holding (6 rows)
- B1 Obligations are written so each can be evaluated on one platform without reference to another.
- B2 Linux holds independently (rootless podman, no sudo, immutable host).
- B3 macOS holds independently (VM boundary, who owns the VM lifecycle, host↔guest channel).
- B4 Windows holds independently (WSL2 distro lifetime, host↔guest channel).
- B5 A per-platform witness exists: something that says PASS/FAIL per platform per release, and a release cannot claim a platform it did not witness.
- B6 Platform divergence is contained: one shared core, thin platform shells; no obligation silently Linux-only.

### C. Credential hygiene (9 rows)
- C1 Complete inventory: every credential named, with mint → store → deliver → reader, no "etc.".
- C2 Nothing plaintext at rest on the host (config, env files, shell history, logs, image layers).
- C3 Forge never holds a long-lived upstream credential; what it does hold is scoped and expiring.
- C4 Delivery channel: not argv, not inherited env visible to siblings, not image layer, not world-readable mount.
- C5 Broker/vault trust root: how it unseals, what a same-user host process can do, what a wipe costs.
- C6 Cross-forge isolation: forge A cannot read forge B's credential or the control socket of another project.
- C7 Fail-closed: when the credential path breaks the forge is refused, never falls back to a weaker path.
- C8 Revocation and lifetime on forge removal; nothing survives teardown.
- C9 Egress control: where a credential can be spent is constrained (proxy/allowlist), and its bypass is closed.

### D. Observability for forge agents (7 rows)
- D1 Event model: typed, versioned, with origin on every record.
- D2 Propagation path host → forge and forge → host is stated end to end, with back-pressure and loss semantics.
- D3 Consumption: an agent inside a forge can actually ask "what is happening / why did X fail / when may I retry" through one interface.
- D4 Visibility scoping: own forge + its children + curated global; no siblings.
- D5 Privacy/retention: logs die with the forge; no secret or PII crosses into shared events.
- D6 No new polling; event delivery cost is consistent with A1/A2.
- D7 Human surface: one curated status line, not a log tail.

### E. Supply-chain provenance (7 rows)
- E1 Cheatsheet provenance annotations: every claim has a source + retrieval date, and a gate that fails on a missing one.
- E2 Provenance is *verified*, not merely present (URL reachable / hash pinned / staleness rule).
- E3 Container images: pinned by digest, built reproducibly or attested; base image updates are a decision.
- E4 Local models: origin, hash, licence recorded before first use; fetch refuses otherwise.
- E5 Per-project licence acceptance: recorded in the agreeing project, bound to a human approval, not transferable between projects.
- E6 Tooling installed into forges (agents, CLIs, language toolchains) is pinned and its fetch failure mode is defined.
- E7 The release artefact itself: signed/attested, and the installer verifies before running.

### F. Earned complexity (6 rows; scored D only, reverse-evidence required)
- F1 Component count vs. obligations served: every component names the obligation it holds; none hold zero.
- F2 No duplicate mechanisms (two ways to deliver a secret, two event buses, two launchers).
- F3 Product vs. process: machinery that serves the fleet's development loop is separated from what ships to an end user.
- F4 Spec/code ratio is honest: spec count and size proportional to what is implemented.
- F5 A newcomer can enumerate the running system from one document in under an hour.
- F6 Deletion test: what can be removed today with no obligation lost (credit for a design that names it; penalty for a system that cannot).

### G. Language direction — Lua/Rust/Go, minimal bash/python (4 rows)
- G1 Measured footprint: lines and file counts of bash and python on the shipped path vs. the dev-only path (current side is *measured*; blind side is scored on what it would require).
- G2 Direction of travel: is there a ratchet that makes the count fall, and has it fallen?
- G3 Shipped runtime path free of bash/python (what an end user's machine executes).
- G4 The choice of Lua vs Rust vs Go per component has a stated reason rather than three languages for one job.

Max D: (7+6+9+7+7+6+4) × 4 = 46 × 4 = 184. Max I: 40 rows × 4 = 160 (F excluded from I; G1/G2 I is "measured").

## Things I will report regardless of score

- Rows where both sides score ≤ 1 on D (shared weakness → suspect the obligation text, per Knight & Leveson).
- Rows where the four blind designs disagree (the disagreement is the information).
- Every blackbox-audit High/Medium: CONFIRMED / REFUTED / NOT REPRODUCIBLE FROM CODE, with the symbol read.
- Where my score depends on a fact I could not verify read-only (marked UNVERIFIED, never rounded up).

## Pre-registered priors (so they can be held against me)

1. I expect the current system to lose F (earned complexity) and G1 heavily and to win every I row; I will not let I leak into D.
2. I expect blind designs to be naive on B3/B4 (VM lifetime) and on A1 (a number nobody measured). If they are not, that is a finding.
3. I expect the credential area to be the place the current system is genuinely ahead in D, not only in I, because fail-closed vault rulings were paid for by incidents. If a blind design matches it, check contamination first.
