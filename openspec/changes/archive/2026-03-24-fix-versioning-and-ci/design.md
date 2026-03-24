## Context
Build counter was resetting because --bump-changes set BUILD=0. Workflows were triggering on every push.
## Decisions
### D1: Monotonic build counter
BUILD always increments: `BUILD=$((BUILD + 1))` in both --bump-build and --bump-changes.
### D2: Manual-only workflows
Both CI and Release use `workflow_dispatch` until signing secrets are configured and verified.
