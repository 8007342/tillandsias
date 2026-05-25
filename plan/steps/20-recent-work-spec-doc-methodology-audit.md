# Step 20 - Recent Work Spec/Docs/Methodology Audit

## Objective

Audit recent work through 2026-05-24, refresh stale specs and cheatsheets, make
the methodology multi-host aware, and distill ad hoc Markdown into canonical
repo-local artifacts.

## Status

Completed and verified in this working batch.

## Owned Files Or File Scopes

- `openspec/specs/git-mirror-service/spec.md`
- `openspec/specs/tillandsias-vault/spec.md`
- `openspec/litmus-tests/litmus-git-mirror-safe-refspec-push.yaml`
- `openspec/litmus-bindings.yaml`
- `docs/cheatsheets/git-mirror-lifecycle-audit.md`
- `methodology/*`
- `plan.yaml`
- `plan/index.yaml`
- `plan/issues/*2026-05-24.md`
- top-level and `.claude` Markdown tombstone pointers

## Dependency Tail

- `user-runtime-checkout-free` completed.
- `launcher-terminal-litmus` completed.
- `doc-debt-payoff` completed earlier but stale in `plan/index.yaml`.
- `release-readiness` and old `post-release-polish` were stale after later
  release recovery and user-runtime release work.

## Current Evidence

- Branch coordination: Claudia reported `linux-next`, `windows-next`, and
  `osx-next` aligned to `ddf52dff` before platform work continued.
- Git mirror safety: spec and cheatsheet now require explicit refspec pushes and
  forbid `git push --mirror` / `git push --all`.
- Vault: spec now reflects Phase 6 Linux default Vault bootstrap, AppRole token
  minting, and deprecated legacy keyring flags.
- Methodology: new `methodology/multi-host-development.yaml` captures branch
  cadence, host identity fields, plan ledger rules, and Markdown distillation.
- Unknown events: events 030 and 031 record multi-host branch coordination and
  Markdown sprawl distillation.
- Verification:
  - `scripts/run-litmus-test.sh git-mirror-service --phase pre-build --size instant --compact` passed.
  - `python3 -c 'import yaml, pathlib; ...'` parsed 56 methodology/plan/litmus YAML files.
  - `bash scripts/validate-spec-cheatsheet-binding-fast.sh` passed at 100% coverage.
  - `scripts/validate-traces.sh` passed with 0 errors and 14 existing warnings.
  - `cargo test -p tillandsias-vault-client` passed.
  - `cargo test -p tillandsias-headless git_run_args_mount_vault_token_when_supplied --features vault` passed.

## Next Action

Adopt `multi-host-plan-ledger-adoption` as the next ready graph node. Future
agents should update plan/event handoffs with `host_id`, `platform`,
`upstream_commit`, and `observed_sibling_heads` before touching shared files.

## Checkpoint And Push Expectation

Checkpoint this audit to `origin/linux-next` after focused validation. If other
hosts have advanced shared files, merge by stable plan/spec IDs rather than
overwriting their notes.

## Handoff Note For The Next Agent

Start with `plan/issues/multi-host-coordination-2026-05-24.md` and
`methodology/multi-host-development.yaml`. Do not depend on hidden memory from
this session or Claudia's session. Treat top-level implementation Markdown as
tombstoned intake unless the audit map says otherwise.

## Repeat-Mode Progress Report Shape

Use `./codex --quiet` or bounded repeat cycles. Report:

- focus task: `recent-work-spec-doc-methodology-audit`
- before/after status
- sibling heads observed
- verification commands and pass/fail state
- next graph node: `multi-host-plan-ledger-adoption`
