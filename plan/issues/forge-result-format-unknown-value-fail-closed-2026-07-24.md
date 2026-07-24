# Unknown delegated-result formats silently disable structured capture

- Packet: `forge-result-format-unknown-value-fail-closed`
- Order: 462
- Status: ready
- Desired release: v0.5
- Owner host: any
- Filed: 2026-07-24 during order429 adversarial review

## Observation

The v0.4 delegated-result contract intentionally activates only when
`TILLANDSIAS_AGENT_RESULT_FORMAT` is exactly `json`; an unset variable keeps the
ordinary interactive path. An adversarial review found that a present but
unknown value, including non-Unicode bytes, currently falls back to that same
ordinary path.

This does not violate the current exact-`json` contract and is not a v0.4
blocker. It is nevertheless a poor automation boundary: a typo or corrupt
launcher value can silently remove current-run capture instead of refusing a
delegated launch. The later failure then looks like missing result evidence
rather than the configuration error that caused it.

## Proposed hardening

Keep unset behavior and exact `json` behavior unchanged. When the variable is
present, require valid UTF-8 and the exact supported value before launching a
Codex or OpenCode CLI worker. Reject every other value with a non-secret
configuration diagnostic. OpenCode Web remains outside the structured-result
contract and must not inherit this internal result-mode variable.

## Exit criteria

- An unset result-format variable preserves the ordinary CLI path.
- Exact `json` preserves current prompted delegated capture for Codex and
  OpenCode CLI.
- Any other present value, including non-UTF8 input, fails before container
  launch with a deterministic configuration classification.
- Deterministic tests cover unset, exact, unknown text, non-UTF8, and Web-mode
  omission without adding or changing an end-user UX surface.
- The active specs state the fail-closed value grammar and keep Web outside the
  structured-result contract.
