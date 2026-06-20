# Meta-Orchestration Enhancement Opportunities — 2026-06-20

- branch: linux-next
- status: in_progress (Candidate 4 completed, candidates 1-3 ready)
- owner_host: any (each candidate names its capability requirement)
- source: meta-orchestration field observations, Cowork scheduled-task runtime,
  cycles 2026-06-20T19:05Z and 2026-06-20T19:15Z (linux_mutable)
- principle: Monotonic Reduction of Uncertainty Under Verifiable Constraints
  (methodology/philosophy.yaml). Each finding below is filed so it cannot be
  lost, then reduced to the smallest packet that closes it under a *verifiable*
  check rather than prose intent. See the Reduction Engine section in
  `skills/meta-orchestration/SKILL.md`.

## Why this file exists

The methodology requires working agents to self-improve by logging
inefficiencies and enhancement opportunities directly into `plan/issues/` as
actionable items (`methodology.yaml` → `cooperative_work_discipline`;
`Non-Negotiable Exit Contract` → "Explicitly log things that make you slower").
This is the intake half of the loop. The reduction half — turning each finding
into progressively smaller, verifiable packets until it closes — is owned by the
recurring `/meta-orchestration` loop. No finding here is terminal until a
verifiable constraint retires it.

## Candidates

### 1. opt/e2e-eligibility-rediscovery (→ index order 60)

- observation: Every Cowork cycle independently re-derives the same verdict —
  `/run/user/<uid>` absent ⇒ no rootless podman user session ⇒ local-build e2e
  not runnable ⇒ skip. The discovery is recomputed from scratch each loop and
  logged afresh in ACTIVE.md / loop_status.md every time.
- evidence: cycles 09:00Z, 17:45Z, 18:35Z, 19:05Z, 19:15Z all carry an identical
  "Skipped — no podman user session in Cowork sandbox (no /run/user)" line.
  `scripts/e2e-preflight.sh` records host/commit/version but has **no** podman
  session-capability probe, so the eligibility decision lives only in agent
  prose.
- cost: repeated step + repeated ledger noise — the exact velocity-killer
  `methodology.yaml` self-improvement rule targets.
- reduction: add a host e2e-eligibility probe that emits a structured verdict
  (`eligible` | `skip:<reason>`), have the skill's E2E Gates consult it, and
  record the verdict once per host run instead of re-deriving it in prose.
  Idiomatic implementation: extend `scripts/e2e-preflight.sh` or add a
  `tillandsias-policy e2e-eligibility` subcommand (shell dispatching the Rust
  tool, per the repo's no-standalone-logic convention). Capability: a
  build-capable host (Rust toolchain) for the policy-subcommand path.
- verifiable closure: the probe returns the correct verdict on both an eligible
  host (podman session present) and the Cowork sandbox (absent), bound by a
  litmus test.

### 2. enh/credential-guard-not-verifiable (→ index order 61)

- observation: the Credential Channel Guard added to
  `skills/meta-orchestration/SKILL.md` at 2026-06-20T19:15Z is **advisory prose**.
  It tells the agent what to check but ships no executable that fails the cycle
  when no credential channel exists.
- evidence: `skills/meta-orchestration/SKILL.md` → "Credential Channel Guard"
  section; `plan/issues/cowork-headless-credential-isolation-2026-06-20.md`
  (the silent-push outage the guard exists to prevent).
- principle tension: `philosophy.yaml` →
  `verification_claims_must_be_falsifiable` and the "verifiable constraints"
  half of the core principle. A guard that only an attentive agent honors is not
  a constraint; it is a suggestion.
- reduction: implement an executable credential-channel check returning exit
  0/non-zero (`.git/.gh-credentials` non-empty, or `GH_TOKEN`/`GITHUB_TOKEN`
  set, or `gh auth status` green) that the loop invokes at start-of-cycle and CI
  can bind. Idiomatic: `tillandsias-policy credential-channel` dispatched by a
  thin `scripts/check-credential-channel.sh`. Capability: build-capable host.
- verifiable closure: check exits non-zero in a scrubbed-environment fixture and
  zero with a seeded `.git/.gh-credentials`; bound by litmus.

### 3. opt/ledger-edit-claim-lease (→ index order 62)

- observation: concurrent agents independently perform and commit identical
  `plan/index.yaml` ledger-hygiene edits (node closures, dup-key fixes), wasting
  effort even though the merges are idempotent.
- evidence: `plan/issues/agent-concurrency-collisions-2026-06-20.md` Observation
  2026-06-20T19:05Z (two agents fixed the same step-58 closure + dup `note:`
  key); this cycle's startup also raced a sibling that had already committed
  `b5484c59`.
- cost: duplicated derivation work; the e2e `.lock` discipline
  (`methodology.yaml` → `clean_workspace_discipline`) covers test execution but
  **not** ledger-hygiene edits.
- reduction: extend the shared-lock discipline to a lightweight, CRDT-friendly
  in-flight "node-closure claim" marker for `plan/index.yaml` hygiene edits so a
  cycle can detect an in-flight closure before re-deriving it. Must respect the
  stable-ID + idempotent-merge preconditions in
  `methodology/between-commits-work-discipline.yaml`. Capability: any host.
- verifiable closure: two concurrent simulated cycles claiming the same node
  produce exactly one closure edit, not two; bound by a concurrency litmus.

### 4. research/cowork-nonpython-ledger-validation (→ index order 63)

- observation: the exit contract's "validate touched YAML with a parser" step
  has no approved validator wired into the Cowork runtime. `tillandsias-policy`
  is not on PATH there, and Python is forbidden for committed automation
  (`methodology.yaml` → `runtime_language_policy.tlatoani_hard_no_python`), so
  cycles fall back to ad-hoc interactive `python3 -c 'import yaml...'`.
- evidence: this cycle — `tillandsias-policy not on PATH; python yaml parse
  sufficient`; tool probe shows `yq: absent`, `ruby: present`, `node: present`.
- risk: validation silently depends on a discouraged interpreter; if a future
  sandbox drops `python3`, the exit contract's validation step breaks quietly.
- reduction: define and document the approved non-Python validation path for the
  Cowork runtime (build + cache `tillandsias-policy validate-yaml`, or a
  sanctioned `node`/`ruby` one-liner as an explicitly interactive-only fallback)
  and name it in the skill's Finalization step so no cycle reaches for Python.
  Capability: any host (research/decision packet).
- verifiable closure: the skill names a concrete, non-Python validator command
  that runs green in the Cowork sandbox; the no-python checker stays clean.

## Triage Outcome — 2026-06-20T19:15Z

All four candidates promoted to `plan/index.yaml` as `ready` packets (orders
60–63), each reduced to a single minimal first task with a named verifiable
closure. None were implemented this cycle: candidates 1, 2, and 4 require a
build-capable host to do the idiomatic Rust-tool implementation, and the Cowork
sandbox cannot build/verify `tillandsias-policy` or run the podman e2e path.
Shaping them into verifiable `ready` packets *is* the reduction step for this
host — the findings are now durable plan state and cannot be lost.

## Events

- type: finding
  ts: "2026-06-20T19:15:00Z"
  agent_id: "linux-macuahuitl-opus-cowork-20260620T1908Z"
  host: "linux_mutable (Cowork)"
  note: >
    Filed four meta-orchestration enhancement/optimization opportunities observed
    while draining the credential-isolation packet and running the coordinator
    pass. Each reduced to a smallest-verifiable-packet candidate and promoted to
    plan/index.yaml orders 60–63. Also encoded the Reduction Engine lifecycle in
    skills/meta-orchestration/SKILL.md so future cycles keep reducing filed
    findings under verifiable constraints and raise the scan bar (warnings,
    errors, deprecation notices) as the terminal-finding rate falls.
- type: claim
  ts: "2026-06-20T19:58:00Z"
  agent_id: "linux-macuahuitl-gemini-antigravity"
  host: "linux_mutable"
  note: >
    Claimed Candidate 4 (non-Python validator) for implementation.
- type: completed
  ts: "2026-06-20T20:00:00Z"
  agent_id: "linux-macuahuitl-gemini-antigravity"
  host: "linux_mutable"
  note: >
    Completed Candidate 4. Documented Ruby's standard YAML library fallback
    `ruby -ryaml -e "YAML.load_file('<file>')"` in the Finalization section of
    skills/meta-orchestration/SKILL.md.

