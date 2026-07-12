# Enhancement: run-litmus-test.sh reports PASS when a name filter matches ZERO tests

- Date: 2026-07-12
- Class: enhancement (gate integrity)
- Found by: linux-macuahuitl-fable5-20260712T1006Z during order-299 verification

## Observation

`scripts/run-litmus-test.sh litmus:brew-ondemand-tools-shape --phase pre-build
--size instant --compact` matched nothing (the positional filter expects a
spec name like `default-image`, not a litmus name) and exited with:

```
Total: 0 (executed: 0, skipped: 0)
Pass Rate: 0% (0/0 executed)
Status: [PASS]
```

A zero-test run reporting PASS is a silent no-op: any gate whose filter
drifts (typo, renamed spec, wrong name form) keeps passing while verifying
nothing. This is the advisory-guard failure class — the check only works if
the invoker notices "executed: 0".

## Reduction (order 300)

Fail loud on an empty selection: when a filter argument was given and zero
tests matched, exit non-zero with `no litmus tests matched filter '<arg>'`
(a filterless run over an empty phase/size bucket may stay a pass). Accepting
`litmus:<name>` as a filter form would also remove the sharp edge. Pin with
an instant litmus asserting the non-zero exit + message.
