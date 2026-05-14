# Plan Step Notes

Each step file should be written as a cold-start handoff document.

## Required Shape

- Objective
- Owned files or file scopes
- Dependency tail
- Current evidence
- Next action
- Checkpoint and push expectation
- Handoff note for the next agent

## Writing Rules

- Assume the next reader may be a different agent with no hidden conversation history.
- Write as if the current agent may be terminated after the checkpoint.
- Include stable step or graph node IDs so repeated updates are idempotent.
- Mention the current branch, checkpoint commit, blocker state, and residual risk.
- Do not depend on scratch notes for canonical meaning.

## Scratch Notes

- Temporary notes belong under `plan/localwork/<step-id>/`.
- Those notes are disposable and may be evicted by age.
- Canonical progress lives in `plan.yaml`, `plan/index.yaml`, and the step file itself.
