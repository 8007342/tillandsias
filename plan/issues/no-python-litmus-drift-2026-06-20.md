# No-Python Litmus Drift - 2026-06-20

trace: methodology.yaml (runtime_language_policy),
       plan/issues/no-python-runtime-policy-2026-06-16.md,
       plan/issues/forge-diagnostics-automation-2026-05-27.md

## Packet

- id: `policy/no-python-litmus-drift`
- type: fix
- owner_host: any
- status: ready
- capability_tags: [litmus, rust, policy, testing]
- discovered_by: `forge-diagnostics/e2e-piggyback-orchestration` no-Python
  drift slice on linux-next, 2026-06-20T07:38Z.
- severity: medium
- blocker: none
- next_action: >
    Replace the remaining `python3` litmus commands with Rust-backed
    `tillandsias-policy` helpers or POSIX shell equivalents, then extend the
    no-Python checker (or add a sibling checker) so litmus YAML command fields
    are scanned before this class of drift can recur.

## Finding

`policy/no-python-runtime-scripts` is marked done and its acceptance evidence
states that no harness, skill, litmus, or repeat path shells out to
`python`/`python3`. A follow-up scan found remaining Python runtime use in
litmus YAML command fields after the diagnostics E2E litmus was fixed.

Current inventory:

- `openspec/litmus-tests/litmus-browser-isolation-e2e.yaml` - OTP generation
  and an in-container OpenCode mock HTTP server.
- `openspec/litmus-tests/litmus-vault-policy-forge-cannot-read-github-token.yaml`
  - JSON token extraction.
- `openspec/litmus-tests/litmus-vault-auto-unseal-no-prompt.yaml` - Vault JSON
  parsing and timestamp emission.
- `openspec/litmus-tests/litmus-macos-tray-menu-renders.yaml` - menu JSON
  assertions.
- `openspec/litmus-tests/litmus-windows-tray-menu-renders.yaml` - menu JSON
  assertions.

The diagnostics E2E litmus is no longer in this inventory after the
2026-06-20 slice added `tillandsias-policy validate-forge-diagnostics-json`.

## Acceptance Evidence

- `rg -n "python3 -c|python3 /tmp|python -c" openspec/litmus-tests` returns no
  active litmus command invocations, except explicitly documented tombstones if
  any are retained.
- Rust or POSIX replacements preserve each litmus's prior assertions.
- `cargo test -p tillandsias-policy` passes if new helper commands are added.
- Touched litmus YAML parses with `tillandsias-policy validate-yaml`.
- The no-Python checker covers litmus YAML command fields or a dedicated
  `check-no-python-litmus` gate is added and recorded in the policy issue.

## Events

- type: discovered
  ts: "2026-06-20T07:38:00Z"
  agent_id: "linux-macuahuitl-codex-20260620T073149Z"
  host: "linux"
  note: >
    Fixed the diagnostics E2E instance in this cycle, then filed this packet for
    the broader remaining litmus YAML inventory to keep the implementation slice
    bounded.
