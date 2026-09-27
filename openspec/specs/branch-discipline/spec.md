<!-- @trace spec:branch-discipline -->
# branch-discipline Specification

## Status

status: draft

Draft filed 2026-09-27 under umbrella 1443-6r3q ("SEED some BRANCH
DISCIPLINE … the git mirror should then respond with the level of branch
discipline being actively enforced for the checked out project"). Change:
`openspec/changes/lua-command-runtime-and-policies/`. Flip to `active` once
1443-w79y, 1443-uit6 and 1443-z3vb close.

## Purpose

A project's branch discipline — the protected default branch, the
integration branch per platform, the work-ref and salvage grammar, the
plan-only lane, the freeze namespace and the operator-worded denial message —
is DATA in the project (`.tillandsias/branch-discipline.yaml`), not a
constant in a tool — and it is checked against what the project's history
and remote actually show. The runtime answers from it (`tillandsias-plan
discipline`, the forge-plan MCP tool), installs the project's hook
templates on demand for its level, the enclave git mirror enforces it at
pre-receive, dispatches the project's own hooks per push event and
publishes the enforced level as a ref, and the land tool asks before it
fetches, gates or pushes. A fresh project pushes to its default branch
freely; raising its level installs its hooks; every refusal names the skill
that explains the work (operator rulings 2026-09-27). Tillandsias's own seed encodes
`methodology/multi-host-development.yaml` → `branch_inventory` and
`branch_namespaces` exactly; the methodology remains the prose authority and
points at the seed as its machine-readable projection.

## Requirements

### Requirement: The seed is per project and has a built-in default
<!-- req-id: 6d0a6170 -->

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
<!-- req-id: 4bd8e7f9 -->

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
<!-- req-id: ad63fc74 -->

The enclave git mirror's pre-receive SHALL read the seed from the
integration branch's tree (level 0 advised when absent) and apply each rule
at ITS enforcement — advised is silent, warn prints the warning and accepts,
enforced rejects — and only where the seed and the derived level agree.
Under an enforced, observed rule it SHALL reject an update to
`refs/heads/<default_branch>` with the seeded message BEFORE relaying and
SHALL reject a new `refs/heads/*` ref outside the seed's grammar; it SHALL
refuse nothing for a project with no seed. On every reconcile tick the
mirror SHALL run the derivation over the mirror repository and keep exactly
one `refs/tillandsias/discipline/<level>/<enforcement>/<derived>/<digest>/<epoch>`
ref pointing at the seed blob, so `git ls-remote origin
'refs/tillandsias/discipline/*'` reads the level actively enforced, the
derived level and the digest without a push. Because `git push --dry-run`
sends no ref commands, a dry-run SHALL NOT be relied on as a probe, and no
probe-push namespace exists (operator ruling 2026-09-27).

#### Scenario: The client reads the enforced level without pushing

- **WHEN** a client runs `git ls-remote origin 'refs/tillandsias/discipline/*'`
- **THEN** exactly one ref is listed and its name carries the level, the
  enforcement word, the derived level and the seed's digest
- **AND** fetching that ref yields the seed bytes

#### Scenario: The floor is absolute at the mirror

- **WHEN** a project with no seed pushes to its default branch
- **THEN** the mirror accepts and relays it with no warning
- **AND** the published ref reads level 0, enforcement advised

### Requirement: The level is derived from observed facts and checked against the seed
<!-- req-id: 31d59cf0 -->

`tillandsias-plan discipline derive [--json]` SHALL observe the project —
the remote's HEAD branch, the integration branches present on origin, the
number of distinct committer hosts in the last 50 commits, the presence of
`work/<id>` refs on origin, pull-request merges on the default branch, and
the hooks installed locally — and print `derived=<level> seed=<level|none>
effective=<level>`, naming each qualifier with its observed value and the
command that observed it. Neither the seed nor the observation is
authoritative alone: a rule SHALL refuse only where the seed says
`enforced` AND the level's qualifier is observed; a seed ahead of reality
SHALL degrade that rule to `warn:discipline:<rule>:seed-ahead-of-reality`
naming the missing qualifier; a project whose observed facts exceed its
seed SHALL be told `discipline raise --to <derived>` with the skill, and
SHALL NOT be refused on the seed's behalf. Observed level 0 SHALL never be
refused (operator ruling 2026-09-27: "derive the discipline but check
against reality").

#### Scenario: A seed ahead of reality warns instead of refusing

- **WHEN** a project's seed says level 2 with `default_branch: enforced`
  but origin has no integration branch and one committer
- **THEN** `check-ref refs/heads/main` prints
  `warn:discipline:default-branch-protected:seed-ahead-of-reality` with the
  missing qualifier in the remedy
- **AND** nothing is refused

#### Scenario: Tillandsias derives its own level

- **WHEN** `discipline derive` runs in this repository
- **THEN** it prints `derived=2 seed=2 effective=2`
- **AND** `check-ref refs/heads/main` stays
  `refused:discipline:default-branch-protected:enforced`

### Requirement: Hooks are templates installed on demand for the project's level
<!-- req-id: df510261 -->

The plan binary SHALL embed one hook template per client event
(`pre-commit`, `post-commit`, `pre-push`, `post-merge`, `post-checkout`)
and per mirror event (`mirror-pre-receive`, `mirror-post-receive`).
`tillandsias-plan discipline install-hooks` SHALL install, into a
repo-local `core.hooksPath` only (refusing a global one), the client hooks
the project's effective level needs — level 0: advisory `post-commit` and
`post-merge` hooks and a `pre-push` that never refuses; level 1: a
`pre-push` refusing the default branch at the seed's enforcement; level 2:
the work-ref grammar and plan-only lane checks — each as a bash-3.2 stub
under sixty lines that execs the sandboxed `lua` CLI and fails closed
without a binary. A project's own `.tillandsias/hooks/<event>.lua` SHALL
override the embedded template. `discipline raise --to <n>` SHALL bump the
seed forward-only and install that level's hooks. Every refusal a template
emits SHALL carry `why:` and
`remedy: this project at level <n> (<rule> <enforcement>) needs <requirement>; use /<skill> for instructions`,
the skill read from the seed's `skills:` map (default `project-discipline`).
A forge SHALL run `install-hooks` for every project it checks out, so the
wiring is the desired state there (operator ruling 2026-09-27).

#### Scenario: A fresh project pushes to main freely

- **WHEN** `discipline install-hooks` runs in a project with no seed
- **THEN** it installs level-0 hooks
- **AND** a push to `refs/heads/main` through them is not refused and
  prints no warning

#### Scenario: Raising the level installs the refusing hook

- **WHEN** `discipline raise --to 1` runs in that project
- **THEN** the seed reads level 1 and the `pre-push` hook refuses
  `refs/heads/main` with a remedy ending
  `use /project-discipline for instructions`
- **AND** `raise --to 0` is refused (forward-only)

### Requirement: The mirror dispatches the project's hooks per push event
<!-- req-id: 172fe67e -->

At `pre-receive` and `post-receive` the enclave git mirror SHALL run the
project's `mirror-pre-receive.lua` / `mirror-post-receive.lua` (its
`.tillandsias/hooks/` override, else the embedded template for its level)
through the plan binary shipped in the git image, sandboxed in the
Observing environment rooted at a scratch export of the pushed tree, with
the command policy restricting `proc.run` to read-only git verbs, no
network, and a 60 s deadline whose expiry rejects the push naming the hook.
A pre-receive refusal SHALL be relayed to the pushing client as the
rejection message together with its `why:` and `remedy:` lines. Dispatch
order SHALL be: project pre-receive hooks, then the seed-level refusals,
then the upstream relay. Post-receive hooks SHALL run only after the relay
succeeded and MAY only log or publish under `refs/tillandsias/<project-hook>/*`.

#### Scenario: The affordance arrives on the push

- **WHEN** a push carries a `mirror-pre-receive.lua` that returns refused
  with a remedy naming `/project-discipline`
- **THEN** the push is rejected and the client's output shows the verdict,
  the `why:` line and the remedy line

#### Scenario: A hanging hook cannot hold the relay

- **WHEN** a `mirror-pre-receive.lua` sleeps past 60 s
- **THEN** the push is rejected with `refused:mirror-hook:timed_out:<hook>`
- **AND** the relay is not invoked

### Requirement: The land tool asks before it fetches, gates or pushes
<!-- req-id: af3add7e -->

`land-on-platform-branch` SHALL run the discipline probe first: `check-ref`
on the requested target, the platform's integration branch from the seed
when no target is named, and the mirror-published digest compared to the
checkout's seed. It SHALL refuse `refused:land:discipline:default-branch-protected`,
`refused:land:discipline:ref-outside-grammar` or
`refused:land:discipline:seed-drift` with `why:` and a `remedy:` ending
`use /<skill> for instructions` (the seed's `skills.land`, default
`project-discipline`) before any network fetch or gate; a seed ahead of
reality SHALL print `land:discipline:seed-ahead-of-reality` and proceed
with the warning; the integration branch SHALL come only from the seed
(per project; a level-0 project lands on its default branch), SHALL print `land:target:<branch>:from=<seed|mirror-ref|default>:level=<n>`,
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
