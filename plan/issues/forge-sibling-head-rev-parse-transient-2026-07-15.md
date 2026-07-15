# Transient sibling-head rev-parse failure right after forge fetch

- **Filed**: 2026-07-15T18:15Z
- **Host**: forge container, linux-next
- **Agent**: forge-fable5-20260715T1811Z
- **Classification**: exploration
- **Related**: plan/issues/git-mirror-fetch-clobbers-exported-ref-2026-07-12.md
  (order 301, done — different symptom, same subsystem);
  order 330 `git-mirror-observability-and-managed-alternatives`

## Observation

At meta-orchestration cycle start (2026-07-15T18:11Z), the standard
sibling-head recording step failed once:

```bash
git fetch origin --prune 2>&1 && \
  git rev-parse --short origin/main origin/linux-next origin/windows-next origin/osx-next
# → fatal: Needed a single revision   (exit 128, no fetch output)
```

Re-running the identical fetch + per-branch rev-parse roughly one second later
succeeded for all four refs (main 38d33cd8, linux-next d9c281b0, windows-next
01b38a0b, osx-next 837b066f). The forge fetches through the enclave mirror
(`git://tillandsias-git/tillandsias`), so a mid-refresh mirror ref snapshot is
one plausible cause; a concurrent parallel `git` invocation in the same cycle
is another. Not reproduced; no functional impact beyond one retried step.

## Second occurrence, same cycle (18:18Z) — consequential, reproduced

The same subsystem question (mirror ref-state freshness) then bit the cycle's
finalization push, with full evidence this time:

- Blind `git push origin linux-next` (through the mirror) was rejected:
  the mirror's atomic relay to GitHub failed with `fetch first` — GitHub's
  `linux-next` was at `b8dcde46` while the mirror still advertised
  `d9c281b0` — and the pre-receive hook correctly refused the ref
  transaction (fail-loud, per the order-301/relay hardening). No credential
  failure; ordinary "remote ahead" semantics surfacing through the relay.
- A follow-up `git fetch origin --prune` STILL returned `d9c281b0`: the
  mirror does not self-reconcile from upstream after a failed relay, and an
  in-forge fetch-through-mirror therefore cannot see the divergence.
  Plausible mechanism: the order-301 fix intentionally removed the
  post-receive upstream fetch (it clobbered just-received refs), so the
  mirror now only learns upstream state at startup/seed time.
- Recovery required bypassing the `insteadOf` rewrite for an anonymous
  direct read: `git fetch https://github.com/8007342/tillandsias linux-next`
  (the no-`.git`-suffix URL does not prefix-match the rewrite rule), then
  rebase onto `FETCH_HEAD` and re-push through the mirror.

Affordance gap distilled: when the mirror is behind upstream, the in-forge
blind push fails and the in-forge blind FETCH cannot repair it — recovery
depends on a non-obvious URL-form bypass no agent should have to know.

## Disposition

Now a shaped, evidenced input for order 330
(`git-mirror-observability-and-managed-alternatives`): the mirror needs
either (a) an upstream reconcile that is safe post-301 (e.g. fetch upstream
into a separate namespace `refs/upstream/*` and expose divergence explicitly,
never clobbering exported refs), or (b) a relay-failure path that refreshes
its upstream view so the NEXT in-forge fetch sees the true head. Cycle-side
mitigations until then: record sibling heads with per-ref `rev-parse`; on a
`fetch first` mirror rejection, fetch the no-`.git`-suffix GitHub URL
anonymously, rebase, re-push.
