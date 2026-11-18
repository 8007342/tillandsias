# Tasks — stale-work-refs-are-defects

Each task's closure is written to fail on the 2026-11-17 state.

- [x] 1.1 The land queue prints an ignored-draft advisory for each draft; arm 7c of `scripts/test-land-queue.sh` fails on the pre-fix queue [2100-vkpg]
- [x] 1.2 Methodology `unlanded_work_is_a_defect`, and the coordinate-multihost-work skill step that lists and acts [2100-vkpg]
- [ ] 2.1 `scripts/lua/check-stale-work-refs.lua --strict` exits 1 on today's 18 drafts, plus fixture arms for draft, PR-less, landed and held [2101-b4pf]
- [ ] 3.1 `stale-work:<drafts>/<prless>` in the coordinator loop status, once a day [2102-9gyk]
- [ ] 4.1 Triage the 18 drafts and 64 PR-less unlanded refs: re-implement, close with a tombstone, or delete; reconcile the 267 ready/in_progress packets whose refs landed [2103-pxq4]
