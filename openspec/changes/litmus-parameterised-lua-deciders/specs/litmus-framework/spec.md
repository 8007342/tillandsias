## ADDED Requirements

### Requirement: A litmus step judges a producer through a parameterised Lua decider

A litmus `command:` whose decision is made over a producer's output (a
cargo test run, a grep over files, a script's verdict, a structured field, a
podman or process probe, a git query) SHALL name a Lua decider on
`tillandsias-plan script run` with its inputs as parameters, and SHALL NOT
pipe the producer into grep, awk, head, tail or test in the command string.
The decider SHALL emit the runner's verdict grammar (`ok:` 0, `refused:` 1,
`blocked:` 2, `could-not-run:` 3, `skip:` 0). An empty population (zero
tests ran, zero files matched, a producer that printed nothing) SHALL be
`could-not-run`, never `ok`. A producer that cannot spawn SHALL be
`could-not-run` naming the tool, never a refusal of the tree. Every non-ok
verdict SHALL print a `why:` and a `remedy:` and SHALL name the failing
thing. Retries SHALL be bounded and SHALL apply only to transient producer
failures, never to a failed assertion. A producer run cached across steps
SHALL be keyed on the tree state and SHALL say `cache=hit|miss|off` on its
verdict line.

#### Scenario: a failing cargo run names its tests

- **WHEN** a `cargo-test` step's crate has one FAILED test and one panic
- **THEN** the step exits 1 with a non-empty `refused:<name>:failed=1` line and its stderr names the test and the `panicked at` line

#### Scenario: zero tests is not green

- **WHEN** a `cargo-test` step's filter matches no test
- **THEN** the step is `could-not-run:<name>:empty-population`, exit 3

#### Scenario: one producer run serves every step that judges it

- **WHEN** two steps in one gate judge the same crate at the same tree state
- **THEN** the second reports `cache=hit` and the producer ran once

#### Scenario: a transient lock is retried, a failed assertion is not

- **WHEN** the producer first prints `Blocking waiting for file lock` and then passes, with `--retries 1`
- **THEN** the step is ok with `attempts=2`; with `--retries 0` it is `could-not-run:<name>:producer-exit=<code>` and the producer ran once
