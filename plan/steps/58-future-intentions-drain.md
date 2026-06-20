# Step 58 - Drain future intentions into planned tasks

- **Status**: ready
- **Owner host**: any
- **Branch**: linux-next
- **Depends on**: None
- **Specs**: None

## Goal

To process all orphaned tasks listed in `future_intentions` of `plan.yaml`, formalizing them into actionable plan steps and issues so builder hosts can pick them up.

## Context

The `plan.yaml` file currently contains several "future intentions" that have not been assigned a specific step or task. Builders need structured plan nodes to work on. This meta-step ensures each intention is properly planned.

## Tasks

- [x] Item 1 drained: "Move CURL installers and manual TAR/GZ manipulation in Containerfile to DNF." → `plan/issues/containerfile-dnf-migration-2026-06-20.md` (ready)
- [ ] Drain next item from `future_intentions` in `plan.yaml`.
- [ ] Convert each drained item into its own issue (e.g., inside `plan/issues/`) and its corresponding step in `plan/index.yaml` and `plan/steps/`.
- [ ] Elaborate on the issue, expanding on what needs to be done.
- [ ] **Important**: Where architectural decisions are required, formalize these as requirements to have discussions with "The Tlatoāni" for approval. Much of the work is self-evident to create tasks from it, but architecture choices need approval.
- [ ] Remove the drained item from `future_intentions` once it has been fully formalized into the `./plan`.

## Progress

- 2026-06-20T01:45Z (linux-macuahuitl-big-pickle): Drained item 1 — created `plan/issues/containerfile-dnf-migration-2026-06-20.md` with full audit, feasibility analysis, and implementation plan. Removed from `future_intentions`.
