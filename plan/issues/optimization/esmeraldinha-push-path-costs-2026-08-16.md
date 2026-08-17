# The unattended push path on a Windows host: a 74-second credential stall the guard reports as healthy, plus two slow-host costs

- classification: optimization
- filed: 2026-08-16 (windows/ESMERALDINHA, cycle 2 Finalization)
- status: credential stall **fixed on this host**; the guard gap and the two
  slow-host costs are open
- related: `plan/issues/cowork-headless-credential-isolation-2026-06-20.md`
  (same family, different mechanism), `scripts/check-credential-channel.sh`,
  `scripts/hooks/pre-push-local-gate.sh` (order 668-2xeh fast lane, 767-iukh
  ledger carve-out), order 614-2gqx (MO-FULL attestation)

## 1. `ok:gh-keyring` is not evidence that an unattended push can authenticate

### Symptom

Three consecutive `git push` attempts from a non-interactive context produced no
output and were killed at 5 and 10 minutes. The only clue was one line:

```
bash: line 1: /dev/tty: No such device or address
```

Meanwhile `scripts/check-credential-channel.sh` returned **`ok:gh-keyring`** and
exit 0, and `git fetch` / `git ls-remote` completed in **864 ms**.

### Measured cause

`GIT_TRACE=1 GIT_CURL_VERBOSE=1 git push --no-verify --dry-run` timestamps:

```
16:40:30.896  git config list --show-scope -z --type=path
16:41:45.033  run_command: 'git credential-store --file=.../.gh-credentials get'
```

**74 seconds inside `git credential-manager get`** before git fell through to the
next helper. Git Credential Manager is configured at **system** scope
(`credential.helper=manager`), so it runs first on every push and, with no tty
and no GUI session, blocks until its own internal timeout.

Reads are fast because a public-repo read is **anonymous** and invokes no
credential helper at all.

### Why the guard passed anyway

`check-credential-channel.sh` accepts `ok:gh-keyring` when `gh auth status`
succeeds. That is true here and says nothing about the push path: `gh auth
status` reads the keyring in-process, while `git push` shells out to whatever
`credential.helper` chain git resolves — which on this host is GCM first.

The guard's own header already warns:

> Reads (`git fetch`/`git ls-remote`) succeeding is NOT evidence of a credential
> channel — public-repo reads are anonymous. Verify write capability explicitly.

**The same argument applies one level in.** `gh auth status` succeeding is not
evidence of a *usable git credential channel* either; it is evidence that a
*different* consumer of the same token works. The guard verifies that a
credential EXISTS, never that `git push` can obtain it without a tty.

### Fix applied on this host

Seed the repo-local store — the guard's own first-choice channel — and **reset
the inherited helper chain** so GCM is not consulted:

```bash
cred="$(git rev-parse --absolute-git-dir)/.gh-credentials"
printf 'https://x-access-token:%s@github.com\n' "$(gh auth token)" > "$cred"
git config --local --add credential.helper ""            # empty value RESETS the chain
git config --local --add credential.helper "store --file=$cred"
```

The empty value is load-bearing: without it the local helper is *appended* to
the system chain and GCM still runs first, still costing 74 s. Result:

| | before | after |
|---|---:|---:|
| `git push --dry-run` | timeout at 120 s | **15.7 s** |
| `git push` (8 commits) | killed at 300 s / 600 s | **16.7 s** |
| guard verdict | `ok:gh-keyring` | `ok:gh-credentials-store` |

### Proposed reduction (verifiable closure)

Add a verdict that tests the push path rather than the token's existence.
`git push --dry-run` against the real remote is the honest probe, but it needs
network. A cheap, offline, decidable proxy exists: **refuse when an interactive
helper precedes a non-interactive one in the resolved chain.**

```
^(ok:[a-z0-9-]+|blocked:interactive-helper-first|missing:no-credential-channel)$
```

`git config --get-all credential.helper` returns the chain in order; if
`manager`/`manager-core`/`osxkeychain`/`wincred` appears before a `store`/`cache`
helper or before an empty reset, and no `GH_TOKEN`/`GITHUB_TOKEN` is set, an
unattended push will stall. Closure: a litmus feeding the checker three
fixtures — GCM-only, GCM-then-store-without-reset, and reset-then-store —
asserting the first two are `blocked:` and the third `ok:`.

Note the middle fixture is the one that matters. It is the state a well-meaning
operator lands in by running the documented seeding step **without** the reset,
and it looks correct in `git config --get-all` output.

### Note on file mode

`chmod 600` on the credential file did not take (mode remains 644) — this
checkout has `core.fileMode=false` on an NTFS volume. Acceptable on a
single-user host and the file lives inside `.git/` so it can never be committed,
but a POSIX host should not assume the mode was applied.

## 2. `gate-stamp.sh verify` costs 11.9 s against a documented "milliseconds"

`pre-push-local-gate.sh` explains its own design:

> Running the full gate inside the hook would be more direct, but **a
> multi-minute hook gets bypassed on its second use and then protects nothing.**
> Hashing the diff costs **milliseconds** and gives the same guarantee.

Measured here: `release-preflight.sh` 980 ms (on budget), `gate-stamp.sh verify`
**11 930 ms**. Total hook ~13 s.

Still far from the multi-minute threshold the rationale fears, so this is
directional rather than urgent — but the argument that protects the hook is an
argument about *cost*, and the cost is 12× its stated budget on the floor host.
Worth a look before it grows.

## 3. Slow-host convergence risk: the branch can move faster than the gate

The pre-push gate on this host takes **345 s** clean and **564 s** after a merge.
During one such run, `origin/windows-next` advanced by **19 commits** from a
sibling. Merging those invalidates the gate stamp, which forces another full
gate — during which siblings may advance again.

Three hosts were pushing concurrently during this cycle (yolanda's attestation
ledger and loop-status fragments arrived mid-run). The failure mode is a
**livelock specific to slow hosts**: a host whose gate is slower than the fleet's
inter-push interval can never present a stamped tree that is still current.

This host got through by pushing within ~30 s of the gate returning. That is luck
plus haste, not a property of the design.

Not proposing a mechanism yet — the honest first step is measurement: record
gate duration and inter-push interval per host, and see whether the margin is
actually shrinking. Filed so the observation is not lost. Note the existing
plan-only fast lane (668-2xeh) and the attestation-ledger carve-out (767-iukh)
already dodge this for fragment-only pushes; it bites only when a push touches
`plan/issues/` or code, as this one did.
