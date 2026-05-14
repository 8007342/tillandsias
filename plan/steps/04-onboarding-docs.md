# Step 04: Onboarding, Discoverability, and Repo Bootstrap Docs

## Status

pending

## Objective

Keep the first-turn forge experience validator-clean and make project discovery explain itself without duplicating old launch contracts.

## Included Specs

- `forge-welcome`
- `forge-shell-tools`
- `forge-environment-discoverability`
- `forge-opencode-onboarding`
- `default-image`
- `project-bootstrap-readme`
- `project-summarizers`
- `remote-projects`
- `gh-auth-script`

## Deliverables

- A coherent onboarding sequence that points at the real source of truth.
- README/bootstrap tooling that is explicit about whether it is live behavior or historical distillation.
- Any historical onboarding placeholder tombstoned cleanly.

## Verification

- Narrow onboarding/docs litmus chain.
- `./build.sh --ci --strict --filter <onboarding-bundle>`
- `./build.sh --ci-full --install --strict --filter <onboarding-bundle>`

## Clarification Rule

- If the spec is only a retroactive artifact, mark it obsolete rather than trying to synthesize live behavior from it.

## Granular Tasks

- `onboarding/welcome`
- `onboarding/shell-tools`
- `onboarding/bootstrap-docs`
- `onboarding/auth-script`

## Handoff

- Assume the next agent may be different.
- Notes should explain the current branch, file scope, checkpoint SHA, residual risk, and the next dependency tail.
- Reapplying the same update must not create duplicate meaning.
