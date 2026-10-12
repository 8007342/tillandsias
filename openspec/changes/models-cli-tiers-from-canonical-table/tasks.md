# Tasks: models-cli-tiers-from-canonical-table (order 482d)

- [x] Canonical table + adapters + resolver under images/inference/tiers/; entrypoint classifies and pulls through it
- [x] tillandsias-models tier_for reads byte-identical copies under images/default/cli/tiers/
- [x] Delta spec: MODIFIED "Models CLI queries available LLM models" (this change)
- [x] litmus:inference-tier-table-migration: byte identity (sha256 of both), adapters cover the table, no inline row; red on a one-byte change
- [x] litmus:forge-environment-discoverability-install-shape: observable tier output instead of the T0/T1 literals
- [ ] Sync the delta into openspec/specs/forge-environment-discoverability/spec.md and archive this change after the PR lands
