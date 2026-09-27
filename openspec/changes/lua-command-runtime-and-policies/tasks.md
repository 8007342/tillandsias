# Tasks — lua-command-runtime-and-policies

Each task is one plan packet (single-session slice) under umbrella
`1443-6r3q`; the packet carries the runnable closure, the pre-fix failure,
the size and the implementer tier. Order is the drain order.

## 1. First usable vertical slice

- [ ] 1.1 `1443-esm5` capture bound on `tillandsias_exec::Command`
      (`truncated`, `dropped`; `proc.run` maps to `ok=false`). S / sonnet.
- [ ] 1.2 `1443-isrk` policy evaluator core: floor + tighten-only seed,
      three rules, called from `proc.run`/`sh.run` before spawn,
      `policy eval` verb, why/remedy. L / opus.
- [ ] 1.3 `1443-8pur` the agent door `tillandsias-plan run … -- <argv>`,
      `--json`, `--argv-json -`, base env only, policy before spawn
      (one `run_verb.rs` with 1375-amye). M / opus.
- [ ] 1.4 `1443-w79y` branch-discipline seed + `discipline` verb + MCP
      `discipline_show` + methodology pointer. M / sonnet.
- [ ] 1.5 `1443-z3vb` land tool discipline probe (bash), before fetch/gate.
      M / opus.
- [ ] 1.6 `1443-sb9b` first script ported: `pre-push-main-branch-affordance`
      to Lua on the sandboxed `lua` CLI, fail-closed stub. M / sonnet.
- [ ] 1.7 `1443-we89` temporary PreToolUse bridge hook with its retirement
      condition. M / opus. (Where the settings entry lives is an open
      question for the operator.)

## 2. Enforcement completes

- [ ] 2.1 `1443-uit6` mirror enforces the seed at pre-receive and publishes
      `refs/tillandsias/discipline/<digest>/<epoch>`; probe namespace.
      L / opus. Depends on 1443-w79y and 1429-4y9f.
- [ ] 2.2 `1443-fpck` fixture filesystem scope in the engine; the litmus
      runner exports the regime. M / opus.
- [ ] 2.3 `1443-9f5w` per-run consent tokens; smoke-skill env mapping with
      `consent_source`. M / opus.
- [ ] 2.4 `1443-w9hf` audit log with redaction; `policy audit`. S / sonnet.

## 3. Doors and the Lua land tool

- [ ] 3.1 `1443-r4cj` MCP `run_command` on project-info. M / sonnet.
- [ ] 3.2 `1443-u66u` `scripts/lua/land-on-platform-branch.lua`, every
      verdict token byte-identical, freeze and borrowed-stamp refusals,
      stub `.sh`. L / opus.

## 4. Migration instruments

- [ ] 4.1 `1443-xkwb` bootstrap-shell allowlist; population lines on the
      three deciders; `check-decider-retirement.sh`. S / sonnet.
- [ ] 4.2 (existing rows, not re-filed) 1384-bqhy `script run` + verdict
      module; 1384-bxhk shell ratchet; 1384-ddua decider pilot;
      902-5bf9 litmus `steps:`; 1384-j3cv build.sh launcher.
- [ ] 4.3 Retire the PreToolUse hook when its printed condition holds
      (1443-8pur and 1443-r4cj closed on every locus; zero deny/ask from
      `caller=pretooluse` for fourteen fleet days; operator flips the Bash
      tool default).

## 5. Spec sync

- [ ] 5.1 The three new capabilities already exist as DRAFT durable specs
      (`openspec/specs/{command-runtime,command-policies,branch-discipline}/spec.md`)
      with stamped req-ids and registry entries, so the experts can answer
      about them now; the deltas under `specs/` here mirror them. On archive,
      sync only the `git-mirror-service` delta and flip the three drafts to
      `active` after L1 verification (methodology/spec-system.yaml
      `draft_to_active_requires_L1_verification`); do not re-add the draft
      requirements.
