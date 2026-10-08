# 1546-b8ba Darwin evidence — 2026-10-03

## Subject and binary

- Implementation subject: `work/1546-b8ba` at
  `e56fe6b6bfe7e746a118ffaa69400053fb04f264`.
- Native probe used without rebuilding:
  `/Users/tlatoani/opencode/tillandsias/target/debug/tillandsias`.
- `environment.txt` records its SHA-256, size, timestamp, version, host and
  shell. `binary-source-row-timestamps.txt` explicitly records the native
  binary timestamp, the then-current source checkout/blob/timestamp, and the
  generated row timestamp. The final timestamp is the `--fresh` observation
  time, not a source-build provenance assertion.

## Falsifier and controls

- The pre-fix native generator falsely refused the supplied native binary as
  stale (exit 2): `pre-fix-native-generator.*`.
- Exact native measurement: pipe producer/matcher statuses were `101 0`; full
  capture producer status and here-string matcher status were both `0`
  (`native-pipeline-statuses.txt`).
- The preserved pre-fix generator fails the extended fixture (exit 1) at the
  long-output control; its raw result is in `pre-fix-extended-fixture.*`.
- The edited generator passes the fixture (exit 0), including a current
  envelope plus long JSON document and a partial `accel_side` producer that
  exits 73 and remains refused: `post-fix-fixture.*`.

## Native result

The real native `--capabilities --fresh` output has an `accel_side=macos-host`
envelope and a valid schema-2-or-later JSON document
(`native-prefix-json-control.txt`). The unchanged generator produced the fresh
row at `darwin-capability-row.generated.yaml`; it is evidence only and was not
placed under `plan/index.d/`.

The delegate did not build a binary, run a full gate, commit, push, claim,
change policy, or write the plan index. Parent review subsequently reran the
fixture successfully after merging trunk, checked shell syntax and whitespace,
and attempted the full `./build.sh --check`: it exited 101 at the existing
`lua_predicate.rs` / `CACHEABLE_STDLIB_GLOBALS` Clippy `nonminimal_bool`
defect, which Linux1538 owns.
This is scoped repair evidence, not a full-green integration receipt.
