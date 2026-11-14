## ADDED Requirements

### Requirement: the release distance is a defined quantity

The release distance `d_v` SHALL be defined as the number of required
(obligation, platform) cells whose state is below the bar, computed under one
named and versioned policy. The grade output SHALL carry the policy name, the
bar, `d_v`, and the denominator as separate fields. A weighted scheme that no
code computes SHALL be reported as `not-implemented`, never as a second number.

#### Scenario: the grade names its policy

- **WHEN** the grade pipeline runs on any tree
- **THEN** its JSON carries `policy`, `bar`, `d_v` and `denominator`, and the
  verdict line prints the same policy name

#### Scenario: two releases under different policies are not compared

- **WHEN** the non-increase check is given a baseline whose `policy` differs
  from the current grade's
- **THEN** it reports `policy-changed` and prints no increase or decrease

### Requirement: status is recorded per obligation and platform

The grade SHALL hold one state for each (obligation, platform) cell, for the
platforms `linux`, `macos` and `windows`. A test record SHALL earn a rung only
for the platform it names. A cell with no record SHALL be reported as
`unmeasured` for that platform, never as satisfied and never omitted.

#### Scenario: a pass on one platform credits one cell

- **WHEN** an obligation required on all three platforms has a green record
  for `linux` only
- **THEN** its `linux` cell is `positively_tested`, and its `macos` and
  `windows` cells keep their lower state with reason `unmeasured`

#### Scenario: a record without a platform earns nothing

- **WHEN** a green record carries no platform
- **THEN** no cell rises and the record is counted under `unattributed`

### Requirement: platform scope is declared

An obligation SHALL be required on all three platforms unless its spec declares
a narrower scope with a `platforms:` line, or its requirement does with a
`platforms:` comment beside the requirement identifier. The extractor SHALL
refuse a platform token outside the closed vocabulary and an empty scope.

#### Scenario: an undeclared spec is required everywhere

- **WHEN** a spec has no `platforms:` line
- **THEN** each of its obligations is required on `linux`, `macos` and `windows`

#### Scenario: a platform-specific spec declares it

- **WHEN** a spec's Status block carries `platforms: macos`
- **THEN** each of its obligations has exactly one required cell, `macos`

#### Scenario: an unknown platform is refused by name

- **WHEN** a spec declares `platforms: linux, freebsd`
- **THEN** the extractor refuses with the spec and the token named

### Requirement: an aggregate never masks a platform

An obligation's aggregate state SHALL be the minimum over its required cells.
Any published count of satisfied obligations SHALL be accompanied by the
per-platform counts, and SHALL NOT exceed the smallest of them over obligations
required on that platform.

#### Scenario: one failing platform fails the aggregate

- **WHEN** an obligation is green on `linux` and `macos` and failed on `windows`
- **THEN** its aggregate is below the bar and the reason names `windows`

#### Scenario: a page without the per-platform counts does not build

- **WHEN** a page prints a satisfied count without the three platform counts
- **THEN** the site's honesty check fails the build

### Requirement: a test binds one scenario

A litmus step SHALL bind a scenario obligation with a `scenario:` key naming
that obligation's identifier. A `requirement:` key alone SHALL earn `traced`
for the requirement's scenarios and no higher rung. A `scenario:` value that
resolves to no obligation SHALL be refused by name.

#### Scenario: a requirement-level key no longer credits every scenario

- **WHEN** a requirement has two scenarios and one enforced, reachable, green
  step carries only `requirement:`
- **THEN** both scenarios are `traced` with reason `requirement-level-only`

#### Scenario: a scenario key credits exactly one scenario

- **WHEN** the same step carries `scenario:` naming the first scenario
- **THEN** the first scenario is `positively_tested` on the record's platform
  and the second is unchanged

### Requirement: every rung has an assigning rule or is named as unassigned

The grade histogram SHALL carry all seven rungs. For each rung the grade SHALL
either apply its rule or list the rung under `unassigned_rungs`:

- `absent`: an identifier named by a binding key or by the committed baseline
  that the extractor does not emit.
- `negatively_tested`: `positively_tested`, plus a green mutation-arm step
  bound to the same scenario on the same platform.
- `runtime_observed`: `negatively_tested`, plus a green record from a runtime
  or post-build phase test bound to the same scenario, from a release-tier run
  on the same platform.
- `evidence_bundled`: `runtime_observed`, plus a verified witness covering
  those records for that platform.

#### Scenario: the histogram has seven keys

- **WHEN** the grade runs on any tree
- **THEN** `histogram` has seven keys and `unassigned_rungs` lists exactly the
  rungs whose rule is not implemented

#### Scenario: a mutation arm earns the negative rung

- **WHEN** a scenario has a green bound step and a green bound mutation-arm
  step on `linux`
- **THEN** its `linux` cell is `negatively_tested`

#### Scenario: a mutation arm that writes nothing earns nothing

- **WHEN** the mutation-arm step's command performs no write
- **THEN** the cell stays `positively_tested`

### Requirement: a platform run exports a witness

A graded platform run SHALL be exportable as a witness: an in-toto Statement
(`https://in-toto.io/Statement/v1`) whose subjects are the litmus file and spec
file digests it ran against and whose predicate lists the platform, the tier,
the runner build identifier, the source revision and one result per test. The
witness SHALL carry no host name, user name or absolute path.

#### Scenario: a run produces one statement per platform

- **WHEN** the witness verb is given a results stream for one platform
- **THEN** it writes one statement whose subjects carry sha256 digests and
  whose predicate names that platform

#### Scenario: host identity is refused

- **WHEN** a candidate witness contains a `host` field or a home-directory path
- **THEN** the verb refuses to write it and names the field

### Requirement: a witness is verified offline from repository bytes

Verification SHALL need only the witness, the repository at the named
revision, and (when signed) the allowed-signers file. A witness whose subject
digest differs from the repository's bytes SHALL earn nothing. The verifier
SHALL report the witness strength (`unsigned`, `signed`) and SHALL NOT report
an unsigned witness as signed.

#### Scenario: a changed test file voids the witness

- **WHEN** a litmus file named as a subject has different bytes at the revision
- **THEN** verification reports `subject-digest-mismatch` for it and the cells
  it covered do not reach `evidence_bundled`

#### Scenario: a flipped result is detected on a signed witness

- **WHEN** one result in a signed witness is changed from `FAILED` to `PASSED`
- **THEN** signature verification fails and the witness earns nothing

### Requirement: non-increase is checked against the committed release baseline

The release non-increase check SHALL compare the current cells with the cells
committed at the previous release cut, cell by cell, and SHALL NOT depend on any
untracked per-checkout file. Added, retired and regressed cells SHALL be
reported as separate counts.

#### Scenario: a fresh clone sees the regression

- **WHEN** a fresh clone with no local grade history holds a cell below the
  rung the committed baseline records for it
- **THEN** the check reports that cell as regressed

#### Scenario: one gain does not hide one loss

- **WHEN** one cell rises and another falls so that `d_v` is unchanged
- **THEN** the check reports `regressed=1` and names the fallen cell

### Requirement: every published obligation says how it is measured

A committed measurability register SHALL list each level-5 obligation with
either the command or grade field that measures it, or `unmeasured` with the
reason and what would make it measurable. A register entry whose measuring
field does not exist in the grade output SHALL fail the register's check.

#### Scenario: the register covers all obligations

- **WHEN** the register check runs
- **THEN** it prints the number of entries, the number measured and the number
  unmeasured, and fails if an entry is missing

#### Scenario: a claimed measurement that does not resolve is refused

- **WHEN** an entry names a grade field the grade JSON does not contain
- **THEN** the check names the entry and fails
