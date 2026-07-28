# Guard `main` against direct pushes and forge cycles running ON main — breach 34e60965 (2026-07-24)

- Date: 2026-07-24
- Class: fix (release discipline + harness guard + ledger reconcile)
- Area: branch protection / meta-orchestration bootstrap / plan-index integrity
- Severity: high (corrupts the release ledger; guarantees a whole-file index conflict at the imminent v0.4 promotion)
- Owner: linux + operator (prong (a) needs the operator's admin token; (b) and (c) are linux)
- Discovered-by: linux coordinator git audit of origin/main, 2026-07-24 cycle
- Status: ready
- desired_release: v0.4

## Breach record (all facts re-verified with git in this cycle)

At 2026-07-24T04:25:43Z, commit `34e60965` was pushed DIRECTLY to `origin/main` by an
antigravity-harness forge cycle running with `main` checked out:

- `git show 34e60965 --stat` — subject `plan(meta-orchestration): reconcile 9 completed
  v0.4 packets + update loop_status`; trailers `Co-Authored-By: Google Antigravity` and
  `Generated-By: tool=antigravity`; `plan/index.yaml` diff is **42,369 lines**
  (+21,919/-20,522 across 4 files) — a wholesale reserialization (even the list indent
  changed: `    - packet_id:` on linux-next vs `  - packet_id:` at 34e60965).
- `git branch -r --contains 34e60965` — `origin/main` ONLY; `git merge-base
  --is-ancestor 34e60965 origin/linux-next` — NOT an ancestor. It sits directly atop
  `667aca15` (release bump) atop `9f196645` (Merge PR #80): a direct push, not a PR
  merge — bypassing the PR/CI promotion discipline every release since PR #79 has used.
- The commit's own `plan/loop_status.md` hunk records the smoking gun:
  `**Host**: forge container, \`main\` (tracking \`origin/main\`), TILLANDSIAS_HOST_KIND=forge`.
- Status flips verified by extracting each packet from BOTH refs. Six contradict
  linux-next's open statuses (linux-next -> 34e60965):
  - order 313 `inference-firstrun-install-resilience`: in_progress -> done
  - order 384 `git-mirror-reconcile-deploy-and-verify`: ready -> done
  - `guest-intentional-ephemeral-reset`: in_progress -> done
  - `mirror-first-seed-vs-launch-readiness-race`: in_progress -> done (ALSO in_progress
    on origin/windows-next AND origin/osx-next — main now disagrees with all siblings)
  - order 452 `concurrent-mirror-forges-current-checkout-and-coherence`: in_progress -> done
  - order 459 `harness-curl-install-launch-time`: in_progress -> done
- One conflicts on RELEASE ASSIGNMENT, not just status: order 407
  `desired-release-backfill` is `v0.5`/ready on linux-next but `v0.4`/done at 34e60965.

## Consequences

1. Three-way v0.4 gate-count disagreement: main claims gates closed that linux-next,
   windows-next, and osx-next all hold open, so any agent bootstrapping from main
   computes the wrong remaining-gate set and can promote v0.4 prematurely.
2. Guaranteed whole-file `plan/index.yaml` merge conflict at the next release promotion
   (linux-next -> main PR): the ~42k-line reserialization conflicts on every hunk.
3. The written rule was bypassed because nothing executable enforces it:
   `skills/meta-orchestration/SKILL.md:112` — "Release: `main` through PR only" — is
   advisory prose. Same lesson as `scripts/check-credential-channel.sh` (its header:
   a guard nothing enforces is a suggestion, not a constraint).

## Proposal (three prongs)

**(a) Operator — GitHub branch protection on main requiring PR.** Document only; do NOT
run from a harness cycle (admin credential). `enforce_admins: true` is load-bearing: the
breach was authored with the operator's own token, so admin bypass must be off. The three
contexts are the CI job display names (`.github/workflows/ci.yml:22,48,64`); CI already
runs on PRs to main (`ci.yml:14`):

    gh api -X PUT repos/8007342/tillandsias/branches/main/protection --input - <<'JSON'
    {
      "required_status_checks": { "strict": false, "contexts": [
        "fmt + workspace check (all targets)",
        "windows tray typecheck (native msvc, all targets)",
        "macos tray typecheck (native aarch64, all targets)" ] },
      "enforce_admins": true,
      "required_pull_request_reviews": { "required_approving_review_count": 0 },
      "restrictions": null,
      "allow_force_pushes": false,
      "allow_deletions": false
    }
    JSON

**(b) Harness-side guard — refuse committable cycles on main.** New executable check
`scripts/check-committable-branch.sh` modeled on `scripts/check-credential-channel.sh`
(falsifiable one-line grammar, pass/fail exit code): exit 0 + `ok:branch-<name>` when
`git rev-parse --abbrev-ref HEAD` is not `main`; exit 1 + `blocked:committable-cycle-on-main`
when it is. Wire it into the meta-orchestration Start-Of-Cycle (step 2, alongside the
Credential Channel Guard, `skills/meta-orchestration/SKILL.md:121-122`) and the
advance-work-from-plan bootstrap, before any committable work. Read-only/inspection
cycles on main remain allowed — the guard gates committable cycles only.

**(c) The reconcile — revert 34e60965 via PR.** A `git revert` of 34e60965 lands on main
through a PR so main's ledger returns to the release-merge lineage (`667aca15`). History
is preserved (no force-push). NOTE: the linux coordinator is executing (c) in the same
cycle that files this packet; its exit criterion below verifies the landing.

## Exit criteria (each backed by a verifiable constraint)

1. **Guard script exists and refuses main** — pinned by a new instant litmus shape test
   `openspec/litmus-tests/litmus-committable-branch-guard-shape.yaml` whose critical
   path (i) runs `bash -n scripts/check-committable-branch.sh`, (ii) runs the script in
   a scratch `git init -b main` clone expecting exit 1 and stdout matching
   `^blocked:committable-cycle-on-main$`, and (iii) runs it on a `linux-next` scratch
   branch expecting exit 0 and `^ok:branch-linux-next$`. Runnable via
   `scripts/run-litmus-test.sh committable-branch-guard --phase pre-build --size instant --compact`.
2. **Bootstrap wiring is real, not prose** — a step in the same litmus test asserts
   `grep -c 'check-committable-branch.sh' skills/meta-orchestration/SKILL.md` >= 1 and
   `grep -c 'check-committable-branch.sh' skills/advance-work-from-plan/SKILL.md` >= 1.
3. **Branch protection active** — operator runs prong (a); verification constraint is the
   executable probe `gh api repos/8007342/tillandsias/branches/main/protection
   --jq '.enforce_admins.enabled and (.required_pull_request_reviews != null)'`
   printing `true`, with the output pasted into this packet before status -> completed.
4. **Reconcile landed via PR** — `git fetch origin` then BOTH of:
   `git diff --quiet 667aca15 origin/main -- plan/index.yaml` exits 0 (main's index is
   byte-identical to the release lineage again), and `git log --first-parent -1
   --pretty=%s origin/main` matches `^Merge pull request` (the revert arrived through a
   PR merge, not another direct push).
5. **No sibling contradiction remains** — `git show origin/main:plan/index.yaml | grep -A8
   'packet_id: mirror-first-seed-vs-launch-readiness-race' | grep -q 'status: in_progress'`
   exits 0, matching linux-next/windows-next/osx-next.

## Non-goals

- NOT rewriting main history (no force-push; revert only — protection then forbids both).
- NOT adjudicating whether any of the 9 packets is genuinely done: evidence-bearing
  completions must re-land on linux-next through the normal ledger flow, per
  `methodology/multi-host-development.yaml:150` (plan conflicts block until reconciled).
- NOT gating read-only inspection of main checkouts — only committable cycles.
