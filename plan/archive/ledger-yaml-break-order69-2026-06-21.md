# plan/index.yaml YAML break introduced by order-69 commit — velocity finding

- branch: linux-next
- status: done
- owner_host: linux_mutable (coordinator)
- source: meta-orchestration loop, 2026-06-21T05:00Z

## What happened

Commit `a6048341` ("feat(investigation): complete Order 69
git-mirror-architecture-verification") left `plan/index.yaml` **invalid YAML**.
At the `nanoclawv2/implementation` task a `status: completed` line was inserted
at 6-space indent — dedented out of its mapping — between the list item `- id:`
and the sibling keys at 10-space indent:

```
        - id: nanoclawv2/implementation
      status: completed          # <- 6 spaces, breaks the map
          owner_host: linux       # <- 10 spaces
```

Parser error: `mapping values are not allowed in this context at line 4183`.

## Impact (velocity)

Every tool that loads `plan/index.yaml` (ready-work enumeration, validators,
any worker drain) fails until fixed. A broken shared ledger blocks all hosts at
once — the highest-fan-out failure mode in the multi-host setup. It also means
the committing cycle skipped the exit-contract "validate touched YAML" step.

## Fix

Re-indented `status: completed` to 10 spaces (aligned with `owner_host`).
`ruby -ryaml -e "YAML.load_file('plan/index.yaml')"` now returns OK.

## Prevention (smallest next action)

The exit contract already says "validate touched YAML with a parser." The gap is
enforcement. Candidate: a pre-commit / pre-push hook (or the existing
`tillandsias-policy validate-yaml`, once on PATH) that hard-fails on invalid
`plan/index.yaml`, so a broken ledger can never be pushed. Tracked as a
prevention idea here; relates to [[release-build-monitoring-2026-06-20]]'s
"fail loud, don't accrete silent breakage" principle.

## Events

- type: finding
  ts: "2026-06-21T05:02:00Z"
  agent_id: "linux-claude-opus48-loop-20260621T0500Z"
  host: linux_mutable
  note: >
    Caught the invalid-YAML ledger break (commit a6048341, order 69) at the start
    of a meta-orchestration loop iteration; re-indented the stray status key and
    validated. Filed as a velocity finding with a pre-push validation-hook
    prevention idea so this high-fan-out failure mode is closed over time.
