# Landing pipeline P6–P8 — design notes (yoga, 2026-11-20)

Status: DRAFT for the coordinator (macuahuitl-fedora). Builds on P1
(2143-z5uj, PR #1230). Operator rulings 2026-11-20 apply: trains gate the
union tree once; scoped batches follow the 2026-09-20 conditions; `--floor`
replaces worker-side `--preflight` for work/* refs; plan-only PRs ride the
plan lane (default on).

Verdict grammar for every packet: one line per candidate or batch,
`<class>:<scope>:<detail>`, ranked
`could-not-run:host:*` > `hold:trunk-red:*` / `hold:native-lint:*` >
`evicted:*` > `flaky:*`, plus `cleared:stale-head:host`.

## P6 — admission lane (`scripts/land-admit.sh`)

Purpose: decide cheaply, before any gate, whether a PR may enter the queue.

- Input: one PR number. It reads `gh pr view --json headRefName,isDraft,labels,headRefOid`.
- Checks, in order, with the first refusal winning:
  1. the ref shape is `work/<NNNN-xxxx>`, otherwise `hold:admit:#N:ref-shape`;
  2. the PR is not a draft, otherwise `hold:admit:#N:draft`;
  3. `--floor` on the head sha, otherwise `evicted:floor:#N:<step>`;
  4. the native-lint attestation (`check-native-lint-attested.sh --hold`):
     rc 3 adds the label `needs:native-lint` and gives `hold:native-lint:<pkg>:<sha>`;
  5. the plan-only classifier: a ledger-only diff is tagged `lane:plan`.
- Output: it adds the label `land:admitted@<sha>`. A new head sha voids it, and
  land-queue re-reads per candidate (P1), so a stale admission prints
  `cleared:stale-head:host`.
- Falsifier fixture: arms for each refusal, each premise asserted first, plus
  a negative control that admits a clean ref.

## P7 — batch and class trains

Purpose: amortise the full gate across compatible PRs.

- Class: `change_class_tier` is computed on the UNION tree of the batch,
  never per member. The highest tier wins.
- Train: up to K admitted PRs in the same class merge into
  `relay/<ts>`, and ONE gate runs on the union.
  - Green: land all members in queue order.
  - Red: bisect by halving. Only the half containing the red is re-gated. A
    member is `evicted:<test>` only when it alone reproduces the red. If the
    red reproduces on trunk, the verdict is `hold:trunk-red:<test>`, routed
    to P11 when it lands.
- Scoped batches use the 2026-09-20 conditions: disjoint `owned_files` and
  no shared generated artefact.
- Native-lint: members holding `needs:native-lint` are excluded from the
  train. Each pass fetches `refs/attest/*`, and a member is re-admitted once
  `refs/attest/native-lint/<sha>` exists.

## P8 — Depends-On stacks

Purpose: land stacked PRs without hand sequencing. This is the yoga gate race,
and today it is solved by stacking locally.

- A `Depends-On: #M` trailer or body line marks a parent.
- A child is not admitted until its parent has landed. Until then it prints
  `hold:depends-on:#N:#M`.
- When the parent lands, the child's work ref is MERGED (never rebased) with
  the trunk. A conflict prints `hold:depends-on:#N:conflict`.
- A child may ride the same train as its parent only when the parent is
  in the same train and ordered first. The union gate covers both.
- Cycles or a missing parent print `could-not-run:host:depends-on-cycle:#N`.

## Open questions for the coordinator

1. The train size K: this draft defaults to 4. Should it be per class?
2. Does a P6 admission label survive a merge of linux-next into the ref
   (a new sha)? This draft says no, and it re-admits.
3. P8: is the trailer or the body line canonical?
