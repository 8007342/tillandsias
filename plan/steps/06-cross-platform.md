# Step 06: Windows and Cross-Platform Leftovers

## Status

pending

## Objective

Retire or narrow the remaining Windows-specific drift after the Linux path is stable.

## Included Specs

- `fix-windows-image-routing`
- `windows-event-logging`
- `wsl-runtime`
- `wsl-daemon-orchestration`
- `update-system`
- `versioning`
- `web-image`
- `zen-default-with-ollama-analysis-pool`

## Deliverables

- Windows-only contracts either live cleanly or are parked as explicit history.
- Version/update behavior remains consistent with the repo’s current release process.

## Verification

- Narrow cross-platform litmus chain.
- `./build.sh --ci --strict --filter <cross-platform-bundle>`
- `./build.sh --ci-full --install --strict --filter <cross-platform-bundle>`

## Granular Tasks

- `cross-platform/windows-routing`
- `cross-platform/wsl-runtime`
- `cross-platform/versioning-and-image`

## Handoff

- Assume the next agent may be different.
- Record the branch, file scope, checkpoint SHA, residual risk, and dependency tail in each note.
- Repeat updates should be safe if the same node and update ID are applied again.
