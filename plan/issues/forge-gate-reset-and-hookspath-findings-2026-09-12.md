# Forge gate findings 2026-09-12: host-tools arm-6 carve-out gap; global core.hooksPath shadowing; worktree reset clobber

KIND: findings / forge gate robustness
DATE: 2026-09-12
HOST: forge-tillandsias
CYCLE: forge-forge-tillandsias-opencode-20260912t022452z

## Summary

Three distinct findings surfaced while getting the pre-push gate
(`./build.sh --check`) green in a forge. Two are code-level, one is a
session-timing observation with reflog evidence. Each has a RECOMMENDED follow-up
for a mutable host; only the first is fixed in this cycle's push.

## Finding 1 (FIXED here): test-host-tools.sh arm 6 ignores the forge openssl carve-out

`check-host-tools.sh` (`ensure_ca_bundle` forge branch) exempts openssl when
`TILLANDSIAS_HOST_KIND=forge` (the CA-generating test `ensure_ca_bundle`
early-returns on forge, so the openssl CLI is genuinely unnecessary). The arm-6
partition property in `scripts/test-host-tools.sh` (added by 1004-cp6p) counts
the DECLARED set from the spec without applying the same exemption, so on a
forge WITHOUT openssl installed it saw `declared=4 seen=3` and RED a
legitimately-equipped host. macuahuitl's carve-out (recorded on 1080-4deb)
added arm 8 (the "does not name openssl" assertion) but never reconciled arm 6.

- RED (this forge, 2026-09-12): `FAIL --platform linux accounts for every
  declared tool declared=4 seen=3 out=[ok:host-tools:linux:gate:3 present ...]`
- FIX: in arm 6, when `TILLANDSIAS_HOST_KIND=forge`, drop the forge-exempt
  tools (`openssl`; predicate mirrors check-host-tools.sh's forge branch) from
  the declared set before counting. Mutable hosts set no such env var, so their
  verdict is byte-identical.
- VERIFIED: `scripts/test-host-tools.sh` exit 0, `--platform linux partitions
  its 3 declared tool(s) exactly`; full gate host-tools step green.

Environment note: openssl is NOT installable in the forge (uid 1000, no sudo,
no brew allowlist) — the 2026-09-10 forge cycle recorded the same blocker for
1080-4deb. Installing it is a false fix anyway: the forge is CA-exempt by
design.

## Finding 2 (WORKAROUND, durable fix deferred to relaunch): the product sets a GLOBAL core.hooksPath that shadows repo hooks

`crates/tillandsias-headless/src/main.rs` `write_forge_gitconfig` writes
`core.hooksPath = /home/forge/.cache/tillandsias/git-hooks` into the forge's
GLOBAL git config (`/home/forge/.gitconfig`) at provisioning time
(`write_forge_repo_gitdir` sets the same for the facade gitdir, which is
correct and per-repo). A global
core.hooksPath REPLACES hooks for EVERY repo, including product test fixtures
that simulate a server-side refusal with a repo-LOCAL pre-receive hook. First
casualty: `scripts/test-land-merges-trunk.sh` arm 3 (order 1064-r8fv) — the
fixture's refusing pre-receive never ran on a forge, so `git push` silently
succeeded and `land-on-platform-branch.sh` read the refusal as success
(`expected [6] got [0]`, `expected [yes] got [no]`).

- RED (this forge, 2026-09-12): all 1064 arms green EXCEPT arm 3; `git push` to
  a fixture repo with `hooks/pre-receive` (refuse, exit 1) returned rc=0.
- Root: `GIT_TRACE` confirmed receive-pack never invoked the hook; `git config
  core.hookspath` resolves to the global value for fixture repos. Setting it to
  an empty string via `-c core.hookspath=` DISABLES hooks entirely; git needs
  the default per-repo behavior, achievable only by removing the global key.
- WORKAROUND (used this cycle): run the gate with
  `GIT_CONFIG_GLOBAL=/tmp/.../gate-gitconfig` — a copy of `/home/forge/.gitconfig`
  minus the `[core] hooksPath` line (safe.directory, credential.helper empty,
  push.default, mirror insteadOf all preserved). With that, 1064-r8fv passes
  8/8.
- DURABLE FIX (relaunch): make forge provisioning set core.hooksPath PER-REPO
  (the facade gitdir already does; the real checkout already gets a local one)
  rather than globally, so repo-local hooks in fixtures behave normally. Until
  then, every forge gate run needs the GIT_CONFIG_GLOBAL filter, and the
  AGENTS/startup runbook should say so.
- NOTE: the real checkout's own `.git/config` pins `core.hookspath=.git/hooks`
  locally, so the real pre-push gate hook still fires when pushing; the mirror
  also enforces the gate server-side, so nothing is weakened at push time.

## Finding 3 (OBSERVED, writer unidentified): a `git reset` clobbered all uncommitted tracked edits mid-cycle

`git reflog` records the real checkout at 2026-09-12 02:48:41 +0000:
`HEAD@{0}: reset: moving to HEAD`. Consequences: BOTH uncommitted tracked-file
edits of this cycle (the ARM 2/ARM 4 additions to
`scripts/test-ledger-write-reaches-its-reader.sh` and the arm-6 forge fix to
`scripts/test-host-tools.sh`) were silently reverted; all UNTRACKED files
(plan fragments, this issue) survived. No `reset`/`checkout --` was found in
`build.sh` or any gate-step source; the 1063-363b tracked-files guard only
VERIFIES and its failure message merely advises `git checkout --` (it never runs
it). The call is likely a fixture or product binary side effect under a
`cd "$ROOT"` assumption. It happened during gate run B (the one that aborted at
1064-r8fv) or between runs B and C.

- Evidence: `git reflog --date=iso -5` (HEAD move at 02:48:41Z from claim
  commit cc283f9ee); `git status` clean for the files that had been edited
  minutes earlier; untracked plan fragments intact.
- Forge rule adopted THIS cycle: commit code edits BEFORE running the gate in a
  forge (the gate validates the committed tree anyway); treat any uncommitted
  tracked edit as disposable until committed.
- RECOMMENDED follow-up: a mutable host reproduces with a marked dirty file,
  runs `./build.sh --check`, and diffs the reflog. If the writer is a gate
  fixture, it must be scoped to its temp dir (the 1063-363b class again).

## Process note

All three were found while doing the one thing the gate exists to force: prove
the tree under test was actually the tree that gets pushed. Two of the three
(the hook shadowing and the reset) would have been invisible to a plan-only
push lane.