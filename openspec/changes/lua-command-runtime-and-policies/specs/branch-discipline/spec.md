## ADDED Requirements

Mirror of the draft durable spec `openspec/specs/branch-discipline/spec.md` (stamped req-ids live there; see tasks.md §5).

### Requirement: The seed is per project and has a built-in default

`.tillandsias/branch-discipline.yaml` SHALL carry `version`, `level`
(the rung of 1363-xp2v's ladder: `0` a bare project pushes freely to its
default branch; `1` an integration branch and pull requests are required;
`2` work refs into the integration branch are required — forward-only),
per-rule `enforcement` (`advised | warn | enforced`, ratcheting per rule,
never for the ladder as a whole), `default_branch`, `integration` (a map
from platform — `linux`, `windows`, `macos`, `forge` — to a branch),
`work_ref` (a regex), `salvage_ref` (a pattern), `plan_only_lane.paths`,
`freeze_namespace` and `messages.default_branch_denied`. A seed whose
integration branch equals its default branch at level 1 or 2, whose regex
does not compile, or whose level is lower than a previously published level
SHALL be refused at load with `refused:discipline-seed:<reason>`. A project
without a seed SHALL be level 0 advised: the remote's HEAD branch is its
default branch, every ref is admitted, NOTHING is refused (the operator's
absolute floor, 2026-09-22), and every answer SHALL say
`source=default level=0 enforcement=advised`. Every answer from a seed
SHALL carry its level and the rule's enforcement.

#### Scenario: Tillandsias's seed reproduces the methodology

- **WHEN** `tillandsias-plan discipline target --platform macos` runs in this
  repository
- **THEN** it prints `osx-next` with `source=seed level=2`

#### Scenario: A bare project is never refused

- **WHEN** `discipline check-ref refs/heads/main` runs in a project with no
  seed
- **THEN** it prints `ok:discipline:default-branch:level=0` and refuses
  nothing

### Requirement: The runtime answers discipline questions

`tillandsias-plan discipline show [--json]`, `discipline target --platform
<p>` and `discipline check-ref <ref>` SHALL answer from the seed.
`check-ref` SHALL print `ok:discipline:<class>` for an admitted ref
(`integration`, `work-ref`, `salvage`, `plan-lane`, `default-branch` at
level 0) and otherwise answer at the rule's enforcement:
`refused:discipline:<rule>:enforced`, `warn:discipline:<rule>` or
`advised:discipline:<rule>`, each with `why:` and `remedy:` lines; the
remedy for the default branch SHALL be the seed's
`messages.default_branch_denied` with branch names substituted. `show --json`
SHALL carry the seed's sha256 digest. The forge-plan MCP server SHALL expose
`discipline_show` returning the same JSON.

#### Scenario: A push to the default branch is answered locally

- **WHEN** `discipline check-ref refs/heads/main` runs
- **THEN** stdout is `refused:discipline:default-branch-protected:enforced`
  (this repository's seed is level 2 with that rule enforced)
- **AND** the remedy line reads the seeded message naming the integration
  branch and the work-ref grammar

### Requirement: The mirror enforces the seed and publishes the enforced level

The enclave git mirror's pre-receive SHALL read the seed from the
integration branch's tree (level 0 advised when absent) and apply each rule
at ITS enforcement: advised is silent, warn prints the warning and accepts,
enforced rejects. Under an enforced rule it SHALL reject an update to
`refs/heads/<default_branch>` with the seeded message BEFORE relaying and
SHALL reject a new `refs/heads/*` ref outside the seed's grammar; it SHALL
always reject a push to `refs/tillandsias/discipline-probe/*` with the
discipline lines in the rejection; and it SHALL refuse nothing for a
project with no seed. On every reconcile tick the mirror SHALL keep exactly
one `refs/tillandsias/discipline/<level>/<enforcement>/<digest>/<epoch>` ref
pointing at the seed blob, so `git ls-remote origin
'refs/tillandsias/discipline/*'` reads the level actively enforced without a
push. Because `git push --dry-run` sends no ref commands, a dry-run SHALL
NOT be relied on as the probe.

#### Scenario: The client reads the enforced level without pushing

- **WHEN** a client runs `git ls-remote origin 'refs/tillandsias/discipline/*'`
- **THEN** exactly one ref is listed and its name carries the level, the
  enforcement word and the seed's digest
- **AND** fetching that ref yields the seed bytes

#### Scenario: The floor is absolute at the mirror

- **WHEN** a project with no seed pushes to its default branch
- **THEN** the mirror accepts and relays it with no warning
- **AND** the published ref reads level 0, enforcement advised

### Requirement: The land tool asks before it fetches, gates or pushes

`land-on-platform-branch` SHALL run the discipline probe first: `check-ref`
on the requested target, the platform's integration branch from the seed
when no target is named, and the mirror-published digest compared to the
checkout's seed. It SHALL refuse `refused:land:discipline:default-branch-protected`,
`refused:land:discipline:ref-outside-grammar` or
`refused:land:discipline:seed-drift` with `why:` and `remedy:` before any
network fetch or gate, SHALL print `land:target:<branch>:from=<seed|mirror-ref|default>:level=<n>`,
SHALL never refuse the default branch at level 0,
and SHALL keep gate-before-push, proof against the remote
(`merge-base --is-ancestor` after fetch), the freeze read through
`refs/tillandsias/freeze/*` and stamp integrity (a
`stale:fixture-borrowed-stamp` verify is never adopted).

#### Scenario: Landing main costs seconds, not a gate

- **WHEN** `land-on-platform-branch main` runs with origin unreachable
- **THEN** it prints `refused:land:discipline:default-branch-protected` and
  the seeded remedy before any `git fetch`

#### Scenario: A work ref lands on the integration branch

- **WHEN** the tool runs with no target on a checkout whose branch is
  `work/1443-z3vb`
- **THEN** it prints `land:target:linux-next:from=seed:level=2` and proceeds
  against `linux-next`
