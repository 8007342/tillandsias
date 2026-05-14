# Step 00: Wrapper Contract and Repo-Local Launch Defaults

## Status

completed

## What This Step Protects

- `./codex <prompt>` remains the default entrypoint for this repository.
- `./codex --repeat <duration> <prompt>` provides the noninteractive autonomous loop.
- The wrapper defaults to the Tillandsias profile without requiring extra flags.
- The working directory stays the current repository root.

## Current Evidence

- `codex` already invokes the codex binary with `-p tillandsias`.
- The wrapper is a thin launcher and does not need a separate plan-specific mode.
- The repeat loop runs `codex exec --color never` on a timer so local progress can continue without the TUI.

## Deliverables

- Keep the `codex` wrapper stable and repo-local.
- Keep the prompt template in `plan.yaml` as the standard hourly continuation command.
- Keep the repeat template in `plan.yaml` as the standard unattended continuation command.

## Verification

- `./codex "Look at ./plan.yaml and continue implementation using ./methodology.yaml"`
- `./codex --repeat 30m "Look at ./plan.yaml and continue implementation using ./methodology.yaml"`
- Confirm the agent reads `./plan.yaml` and `./methodology.yaml` from the current repo.

## Update Rule

- Do not reopen this step unless the wrapper stops selecting the Tillandsias profile by default.
