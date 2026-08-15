## Cycle 2 2026-08-15 tlatoani (linux_immutable) — a finding you don't push is a finding you destroyed

**Deliberate batch deviation, recorded.** `select-work-batch.sh linux` picked
`socket-audit-master` (score 27.151, seed `host-20260815`, urgent 722-ecne p0).
I drained **741-3y48** from `forge-local-experts-milestone` (the frontier's #2 at
25.710) instead. Reason: until it is fixed, EVERY in-forge validation this
operator runs tonight silently discards its findings — so the fix compounds
across the remaining cycles, and the selector's epic choice is entropy-weighted
rather than a mandate. 722-ecne remains p0 and unclaimed for a later cycle or
another host.

The forge's checkout is a `git clone` into the container
(`lib-common.sh:checkout_forge_seed_branch`), ephemeral by design and correctly
so. The defect was that the durable OUTPUT had no path off that substrate, and
nothing refused when work was about to be lost.

- NEW `scripts/check-forge-findings-persisted.sh` — a GATE (not advisory, unlike
  the health probe: a missing expert costs read latency, an unpersisted finding
  is completed work thrown away, unrecoverably). Covers `plan/index.d/`,
  `plan/loop_status.d/`, `plan/issues/`, `plan/mo-full-attestations.d/`.
- It catches what `git status` CANNOT: a COMMITTED but unpushed fragment
  presents as a clean tree. The litmus asserts the tree is clean AND the gate
  still fails — that is the whole 2026-08-15 loss shape, and a check built on
  working-tree dirt alone would wave it through to teardown.
- NEGATIVE CONTROL, verified against a real repo with a real bare remote rather
  than by inspection: a cycle that files nothing prints `ok:no-findings` and is
  silent. A gate that nags every clean cycle is one every agent learns to ignore.
- Forge startup context gains a `THIS CHECKOUT IS EPHEMERAL` section — the one
  surface every in-forge agent reads regardless of which skill it loads. It
  names the loss, the gate, and what to do when pushing is genuinely impossible
  (reproduce every finding in final output; do not exit quietly).
- Finalization step 8 runs the gate.
- Pinned by NEW `litmus:forge-findings-persistence-shape` 8/8. Spec suite 13/13
  PASS (100%). Fixture 6/6.

Exit criteria 2/3/4 met; criterion 1 — an end-to-end demonstration through a real
teardown — is this cycle's in-forge validation, so 741-3y48 stays `implemented`
rather than closed.

Start-of-cycle: preflight ok, guards ok (`ok:gh-keyring`, `ok:branch-linux-next`,
`ok:expert-base-ready`), **`ok:experts-healthy`** from last cycle's probe now
running as a standing step, `ok:clean-tree`, stranded `in_progress=1 stranded=0`.
Siblings: main 9d2ec03a, linux-next 53584293, windows-next 854f97e5 (advanced),
osx-next b7399e45.

Release: untouched. This host does not own releases.
