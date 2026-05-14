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
- Repeat-mode progress report shape, if the step is intended to run under `./codex --repeat`

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

## Repeat Output

When a step is run under repeat mode, the agent should end with a compact JSON
progress report that can be rendered into a small graph:

- current progress before and after the run
- delta for the run
- a recent trend window
- the latest milestone label and timestamp
- next action and blockers
- focus task, ready count, blocked count, and compact task tree if available
- loop state so the wrapper can distinguish "waiting on agent" from
  "sleeping until next iteration"

The wrapper will use that report to print the human-facing graph.
