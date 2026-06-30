# Litmus harness: critical_path steps ignore success_pattern + mangle backslash commands (yq-less)

- branch: linux-next
- status: ready
- owner_host: linux_mutable (coordinator); harness fix needs build-capable host
- source: meta-orchestration loop e2e step1 `--ci-full` failure, 2026-06-21T06:30Z

## Summary

`litmus:nanoclawv2-mcp-shape` step 2 ("verify allowlist enforces 5 approved
tools") FAILed `--ci-full` pre-build litmus, blocking local-build e2e on
`linux-next`. Diagnosis uncovered **three** layered defects in
`scripts/run-litmus-test.sh`, not a real product regression (the allowlist has 14
`nanoclaw.` entries; the contract holds).

## Defects

1. **critical_path steps ignore the declared `success_pattern`.** Steps with a
   `command:` are scored by the `expected_behavior` heuristic `case` statement
   (run-litmus-test.sh ~L411–501), which keyword-matches phrases ("multiple",
   "succeeds", "at least one", …) and otherwise does a literal substring match of
   `expected_behavior` against the command output (L497). `check_signal()`
   (L391–409) — the only function that honors `success_pattern` — is **not** used
   for these steps. Consequence: this step's `success_pattern: "^[5-9]$|^[1-9][0-9]"`
   was dead. A numeric threshold like "≥5" is inexpressible via the heuristic
   (it only does ≥1 / ≥2). Output `14` with a passing success_pattern still FAILed.

2. **Backslash-escaped command patterns are mangled in the exec path.** Even with
   `yq` extracting `grep -c 'nanoclaw\.'` correctly (verified: runs → 14
   standalone), the runner's `bash -c "$command"` path (L388) yielded `output=0`
   — the `\.` collapses to match a literal backslash (`grep -c 'nanoclaw\\.'` = 0).
   Any litmus command relying on a regex backslash is fragile; **55** litmus files
   under `openspec/litmus-tests/` contain `command:` lines with `\\`.

3. **yq provisioning gap.** `yq` is the harness's primary parser (first choice in
   every `get_yaml_value`/step parser); without it the bash fallback can't extract
   nested `critical_path` fields (returns empty `success_pattern`, mangles
   escapes). This host had **no yq**. Installed `mikefarah/yq v4.53.3` to
   `~/.local/bin` this cycle (user-space, no sudo) — but note this alone did NOT
   fix the step, because of defects 1 and 2.

## Fix applied (this cycle)

Rewrote step 2 to be self-validating and parser-robust — no regex backslash, and
an assertion the heuristic can score:

```yaml
command: "test $(grep -cF 'nanoclaw.' crates/.../allowlist.rs) -ge 5 && echo allowlist-enforced"
success_pattern: "allowlist-enforced"
expected_behavior: "allowlist-enforced"
```

`grep -cF` (fixed-string, no backslash) + the `≥5` check in-command + a sentinel
`allowlist-enforced` that the substring fallback matches. All 7 steps now PASS.

## Recommended durable fixes

- id: critical-path-honor-success-pattern
  status: completed
  order: 74
  action: >
    Route critical_path command steps through `check_signal()` (or the Rust
    `tillandsias-litmus-rust` runner, which parses success_pattern) so the
    declared `success_pattern`/`failure_pattern` are authoritative and numeric
    thresholds are expressible. Today the expected_behavior heuristic silently
    overrides them.
  outcome: >
    Implemented in scripts/run-litmus-test.sh. The critical_path YAML parser
    now extracts success_pattern and failure_pattern per step; the scoring loop
    uses check_signal() when success_pattern is declared, falling back to the
    expected_behavior heuristic otherwise. 112/112 instant litmus tests pass.
- id: provision-yq-on-build-hosts
  status: ready
  action: >
    Add `yq` (mikefarah, Go binary) to the documented build-host toolchain / forge
    image so litmus parsing is correct everywhere, OR harden the bash fallback to
    unescape YAML and parse nested critical_path fields. Audit the 55 litmus files
    using `\\` in commands for the same mangling. Relates to
    [[ci-blockers-fmt-drift-and-litmus-concurrency-2026-06-21]] and order 63
    (non-Python YAML tooling).

## Events

- type: finding
  ts: "2026-06-21T06:32:00Z"
  agent_id: "linux-claude-opus48-loop-20260621T0632Z"
  host: linux_mutable
  note: >
    Root-caused the --ci-full pre-build litmus block to a harness eval gap, not a
    product regression: critical_path steps score via the expected_behavior
    heuristic and ignore success_pattern, numeric ≥N thresholds are inexpressible,
    and backslash command patterns mangle to 0 in the exec path; yq was also
    absent (installed v4.53.3 to ~/.local/bin). Fixed the step with a backslash-
    free, self-validating sentinel; all 7 steps pass. Filed durable harness fixes.
- type: completed
  ts: "2026-06-21T12:49:07Z"
  agent_id: "linux-macuahuitl-big-pickle-20260621T124907Z"
  host: linux_mutable
  note: >
    First durable fix (critical-path-honor-success-pattern) completed as order
    74. The critical_path YAML parser now extracts success_pattern/failure_pattern;
    steps with a declared success_pattern route through check_signal() instead of
    the expected_behavior heuristic. 112/112 instant litmus tests pass.
    Second fix (provision-yq-on-build-hosts) remains ready for pickup.
