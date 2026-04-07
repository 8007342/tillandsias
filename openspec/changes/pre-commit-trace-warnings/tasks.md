# Tasks

- [x] Create `scripts/hooks/pre-commit-openspec.sh` with ghost trace check
- [x] Add zero-trace spec check to the hook
- [x] Add active change staleness check (7-day threshold)
- [x] Ensure hook ALWAYS exits 0 (non-blocking)
- [x] Create `scripts/install-hooks.sh` (idempotent installer)
- [x] Handle existing pre-commit hooks (append, don't overwrite)
- [x] Test hook manually against known issues
- [x] Create OpenSpec change artifacts
