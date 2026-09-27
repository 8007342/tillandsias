## ADDED Requirements

### Requirement: Pre-receive enforces the project's seeded branch discipline

The git service's pre-receive hook SHALL read
`.tillandsias/branch-discipline.yaml` from the tree of the project's
integration branch (level 0 advised when the file is absent: nothing is
refused — the operator's absolute floor, 1363-xp2v ruling 2026-09-22) and
SHALL apply each rule at its own `enforcement` (advised: silent; warn: the
warning, accepted; enforced: rejected) and only where the seed and the
derived level agree (a seed ahead of reality degrades the rule to the
warning naming the missing qualifier), before `tillandsias-relay-refs`
runs: under an enforced rule, reject any update to
`refs/heads/<default_branch>` with the seed's `messages.default_branch_denied`
text (branch names substituted) as the rejection message; under an enforced
rule, reject a new `refs/heads/*` ref whose name matches neither the
integration branches, the `work_ref` regex, the `salvage_ref` pattern nor
the reserved names, with the grammar hint (under warn, today's warning).
No probe-push namespace exists (operator ruling 2026-09-27; a rejected push
was never load-bearing anywhere). Fast-forward updates to an integration
branch SHALL relay exactly as before.

#### Scenario: A push to the default branch is refused before relay

- **WHEN** a client pushes to `refs/heads/main` on a project whose seed
  names `main` as `default_branch`
- **THEN** the hook rejects the update with the seeded message
- **AND** `tillandsias-relay-refs` is not invoked for that transaction

#### Scenario: A grammar violation is answered at its rule's enforcement

- **WHEN** a client creates `refs/heads/feature-x` under a seed whose grammar
  rule is `enforced`
- **THEN** the hook rejects it naming the grammar hint
- **AND** `refs/heads/work/1443-uit6` in the same session is accepted
- **WHEN** the grammar rule is `warn` (this repository today)
- **THEN** the hook accepts it with the warning and accepts `work/<id>`
  without one

#### Scenario: A project without a seed is never refused

- **WHEN** the integration branch's tree has no
  `.tillandsias/branch-discipline.yaml`
- **THEN** a push to its default branch is accepted and relayed with no
  warning
- **AND** the published discipline ref reads level 0, enforcement advised

### Requirement: The mirror publishes the enforced discipline as a ref

On every reconcile tick (the same tick as the upstream-auth probe) the git
service SHALL keep exactly one ref
`refs/tillandsias/discipline/<level>/<enforcement>/<derived>/<sha256-prefix>/<epoch>`
pointing at the seed blob (or at the built-in level-0 default rendered as
YAML when the project has no seed), where `<derived>` is the level
`tillandsias-plan discipline derive` observes over the mirror repository on
that tick, replacing the previous ref when the seed or the derivation
changes, so that a client's `git ls-remote origin
'refs/tillandsias/discipline/*'` reads the level actively enforced, the
derived level and the digest, and a fetch of the ref yields the seed bytes. The ref SHALL NOT be relayed
upstream. A `git push --dry-run` SHALL NOT be documented as a discipline
probe, because it sends no ref commands and the hook never runs for it.

#### Scenario: One ref, replaced on change

- **WHEN** the seed on the integration branch changes
- **THEN** after the next tick exactly one discipline ref exists and its
  name carries the new digest

### Requirement: The mirror dispatches the project's own hooks per push event

At `pre-receive` and `post-receive` the git service SHALL run the project's
`mirror-pre-receive.lua` / `mirror-post-receive.lua` (its `.tillandsias/hooks/`
override, else the embedded template for its level) through the plan
binary shipped in the git image, sandboxed in the Observing environment
rooted at a scratch export of the pushed tree, with `proc.run` restricted
by the command policy to read-only git verbs, no network, and a 60 s
deadline whose expiry rejects the push naming the hook. A pre-receive
refusal SHALL be relayed to the pushing client as the rejection message
with its `why:` and `remedy: … use /<skill> for instructions` lines.
Dispatch order SHALL be project pre-receive hooks, then the seed-level
refusals above, then `tillandsias-relay-refs`; post-receive hooks run only
after the relay succeeded and MAY only log or publish under
`refs/tillandsias/<project-hook>/*`.

#### Scenario: The affordance arrives on the push

- **WHEN** a push carries a `mirror-pre-receive.lua` that returns refused
  with a remedy
- **THEN** the push is rejected and the client's output shows the verdict,
  the `why:` line and the remedy line naming the skill
- **AND** `tillandsias-relay-refs` is not invoked

#### Scenario: A level-0 project with no templates is untouched

- **WHEN** a project with no seed and no `.tillandsias/hooks/` pushes to
  its default branch
- **THEN** the push is accepted and relayed with nothing extra printed

#### Scenario: The client reads the seed without pushing

- **WHEN** a client fetches the discipline ref and runs `git cat-file -p` on
  it
- **THEN** the output is byte-identical to the seed on the integration
  branch
