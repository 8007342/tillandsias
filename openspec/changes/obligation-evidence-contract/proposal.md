# Proposal — obligation-evidence-contract

Umbrella packet: `2080-3tzc`. Source: the 2026-11-09 clean-room exercise
(`plan/issues/observatorium-blind-design-2026-11-09/`), the operator ruling of
2026-11-11 on per-platform obligations, and the research report
`plan/issues/level5-obligation-defects-2026-11-11.md`.

Status: approved by the operator on 2026-11-11 (relayed by the coordinator),
together with the change of denominator to (obligation, platform) cells. The
decisions and the questions still open are in `design.md`.

## Why

The public level-5 document states a release rule ("non-increase of d_v") and a
seven-rung evidence chain. Measured on trunk `e1f8d7f01` with
`scripts/centicolon-grade.sh`:

| fact | value |
|---|---|
| obligations (70 requirement-only + 1504 scenario) | 1574 |
| satisfied | 0 |
| reason `no-binding` | 1569 |
| litmus files / files carrying a `requirement:` key | 629 / 3 |
| rungs any code assigns | 3 of 7 (`declared`, `traced`, `positively_tested`) |
| platform dimension in the grade | none (a record's `regime` is copied, never required) |
| exportable witness for a pass | none (the results stream is a host-local log) |

Six defects follow, none with a plan row before this change:

1. `d_v` has no definition; the only live number is an unweighted count.
2. The grader's binding population is 5 of 1574, and a `requirement:` key
   credits every scenario under that requirement at once.
3. Four rungs are assigned by no code.
4. No obligation states which platforms it must hold on, so one platform's pass
   can stand for all three. Operator ruling 2026-11-11: an obligation holds
   independently on each of Linux, macOS and Windows; a platform-specific
   obligation declares its scope; an aggregate never masks a platform failure.
5. A reader cannot verify `runtime_observed` or `evidence_bundled`.
6. Eleven of the 29 level-5 obligations cannot be measured as written.

## What Changes

- **New capability `obligation-evidence`**: the contract the CentiColon grader,
  the release cut and the observatorium share.
- The release distance is defined: `d_v` is the count of required
  (obligation, platform) cells below the bar under a named, versioned policy.
- Status is recorded per (obligation, platform). Platform scope defaults to all
  three and a narrower scope is declared in the spec.
- A litmus step binds one scenario with a `scenario:` key; a `requirement:` key
  alone earns `traced`, never a test rung.
- Each of the seven rungs has one assigning rule, or the grade says by name that
  nothing assigns it.
- A platform run exports a witness: an in-toto Statement with a test-result
  predicate, bound by digest to the litmus and spec bytes, with no host name.
- The release non-increase check reads the committed release baseline.
- A measurability register lists every level-5 obligation with its measuring
  command or the reason it is not measured.

Nothing here enables a refusal on push. Every new check lands as a report
(`warn:` / advisory); turning one into a refusal is a bar raise the operator
approves separately (`methodology/convergence.yaml` → `approved_bar_raises`).

## Capabilities

### New Capabilities

- `obligation-evidence`: release distance, per-platform cells, platform scope,
  scenario binding, rung assignment, witnesses, committed baseline,
  measurability register.

### Modified Capabilities

None in this change. `observability-convergence` still describes the retired
signature-log dashboard; reconciling it is a follow-up once this capability is
archived.

## Impact

- `scripts/lua/centicolon-extract.lua`, `centicolon-grade-static.lua`,
  `centicolon-grade-observed.lua`, `check-centicolon-ratchet.lua` (Lua).
- `crates/tillandsias-plan` (Rust): a witness emit/verify verb; `obligation.rs`
  is unchanged (it already models seven rungs).
- `methodology/math-foundations.yaml`: the `d_v` definition and the policy name.
- `openspec/specs/*/spec.md`: a `platforms:` line where a spec is narrower than
  all three.
- `observatorium/` (existing Node site): per-platform columns, witness route,
  measurability page.
- The public level-5 text lives in the tillandsias.org repository and is updated
  through the website queue after the methodology text lands.

No new shell or Python, and no jq.
