## ADDED Requirements

### Requirement: Stable promotion advances the deploy refs and verifies them

After `scripts/promote-stable.sh` verifies the `stable` tag on origin, it SHALL
advance `refs/heads/deploy/observatorium` to the promoted release's tree with
`scripts/advance-deploy-ref.sh`, and `demote` SHALL advance it to the restored
release's tree. The helper SHALL push the release commit when the move is a
fast-forward. When it would be a rewind, it SHALL push a restore commit (tree =
the release's, first parent = the release, second parent = the old tip). It
SHALL push nothing when the tip already carries the tree. It SHALL verify
origin's tip by tree and print `verified:deploy-ref:<sha>:tree=<tree>` or a
`refused:deploy-ref-*` line. A refused or unverified advance SHALL print
`HALF-PROMOTED` with its remedy, and the run SHALL exit non-zero without a
`promoted:` line.

`pre-push-local-gate.sh` SHALL exempt a push of `refs/heads/deploy/*` from the
gate stamp only when every ref in the push is a tag or deploy-ref update whose
commit is on freshly fetched `main`. A deploy-ref restore commit SHALL count
as on `main` only when its tree equals its first parent's and that parent is
on `main`.

#### Scenario: a promotion that cannot move the deploy ref is not a promotion

- **WHEN** the stable tag is verified on origin but the deploy-ref push is refused
- **THEN** the output carries `HALF-PROMOTED` and `refused:deploy-ref-push-refused:<sha>`
- **AND** no `promoted:` line is printed and the exit status is non-zero

#### Scenario: a deploy-ref commit with a new tree keeps the gate

- **WHEN** a push to `refs/heads/deploy/observatorium` carries a commit whose first parent is on `main` but whose tree differs from it
- **THEN** pre-push prints `note:pre-push:tag-on-main:not-on-main:refs/heads/deploy/observatorium`
- **AND** the push needs a fresh gate stamp
