# git-mirror relay reconcile no longer fast-forwards exported heads — order 413 regressed order 369

- date: 2026-07-18
- filed_by: linux-macuahuitl-opus48 (host-side mirror investigation after recovering Hy3's stuck forge commits)
- host: linux
- order: 415
- status: ready
- kind: bugfix
- deliverable: images/git/relay-refs.sh
- related:
  - order 369 (git-mirror pre-reconcile: rejected stale push auto-reconciles exported heads)
  - order 413 (git-mirror-relay-fetch-before-push, commit b49b7776) — the regressor
  - order 414 (git-mirror-relay-token-renewal) — sibling relay fix, same file
  - openspec/litmus-tests/litmus-git-mirror-relay-verified-ack.yaml
  - scripts/test-git-mirror-relay-verified-ack.sh (the failing fixture, case 4)

## What happened

`scripts/test-git-mirror-relay-verified-ack.sh` **case 4 fails on a clean
`linux-next`** (reproduced on the pristine tip, independent of order 414):

```
FAIL: case4: mirror main <RECONCILED> did not fast-forward to upstream <UPSTREAM_NEW>
```

Cases 1–3 pass. Case 4 is the order-369 auto-reconcile guarantee: when upstream
has advanced independently and the relay rejects a stale forge push, the
failure path MUST fast-forward the mirror's **exported** `refs/heads/*` from
upstream — so the client's ordinary fetch/rebase/retry loop converges through
the mirror alone — while a locally stranded same-named head survives untouched.

## Root cause

Order 413 (commit `b49b7776`, "relay-refs.sh fetches upstream BEFORE pushing")
rewrote the reconcile fetch. It now runs, on both the pre-push and post-failure
paths:

```sh
git fetch "$PUSH_URL"          # $PUSH_URL is a URL, not a named remote
```

`git fetch <URL>` **with no refspec** writes only `FETCH_HEAD`; it updates
**nothing** under `refs/`. So the mirror's exported `refs/heads/main` is never
advanced, and case 4's fast-forward assertion fails. The reconcile logs
"Reconcile fetch succeeded" (the fetch itself returns 0), which is why the
earlier `grep -Fq "Reconcile fetch"` assertion still passes — a quiet
false-success one layer down.

This is a direct collision between two prior fixes:

- Order 369 reconciled exported heads with `+refs/heads/*:refs/heads/*`.
- Order 413 deliberately removed that refspec because, run while upstream was
  stale, it **clobbered a just-received exported ref** before the relay
  forwarded it (git-mirror-fetch-clobbers-exported-ref-2026-07-12). The litmus
  even hard-asserts the dangerous forced refspec is gone
  (`! grep -Fq "'+refs/heads/*:refs/heads/*'"`).

413 fixed the clobber by throwing out the reconcile's ref-updating behavior
entirely, rather than making it **fast-forward-only**. The result satisfies
413's litmus but silently breaks 369's.

## Why it matters

The order-369 guarantee is the whole reason an unattended forge agent can
recover from "another host pushed while I was working": it fetches the
reconciled head from the mirror, rebases, and retries. With the exported head
never advancing, the mirror stays permanently behind upstream and the client's
retry loop cannot converge through the mirror — every diverged push is a dead
end until a host-tier operator intervenes (exactly the manual recovery this
whole mirror-ladder is meant to eliminate).

## Smallest correct fix (exit criteria)

1. The post-failure (and pre-push staleness) reconcile fast-forwards the
   mirror's exported `refs/heads/*` to upstream **fast-forward-only** — never a
   forced update — so a locally stranded (non-ancestor) head is preserved.
   Concrete shape: fetch upstream into `refs/remotes/origin/*` (safe tracking
   refspec, already the configured default), then advance each
   `refs/heads/<b>` to `refs/remotes/origin/<b>` **only when** the current head
   is a strict ancestor (`git merge-base --is-ancestor`). Non-ancestor heads
   (the stranded case) are left as-is.
2. `scripts/test-git-mirror-relay-verified-ack.sh` case 4 passes AND the
   clobber-guard shape asserted by `litmus:git-mirror-relay-verified-ack`
   (no `+refs/heads/*:refs/heads/*`) still holds — both fixes coexist.
3. Re-run both litmus fixtures green: relay-verified-ack and
   git-mirror-fetch-reconcile.

## Repro

```
git switch --detach origin/linux-next
scripts/test-git-mirror-relay-verified-ack.sh   # case 4 FAILs, cases 1-3 pass
```
