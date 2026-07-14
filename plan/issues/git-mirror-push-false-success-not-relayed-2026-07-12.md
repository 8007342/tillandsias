# P1: enclave git mirror reports push success but never relays to GitHub — silent false-success

- Date: 2026-07-12
- Class: bug (P1, git-mirror-service; data non-delivery with a success signal)
- discovered_by: operator attended m8 smoke (macOS, osx-next) + macos
  meta-orchestration cycle verification
- Related: `forge-mirror-insteadof-missing-2026-07-12.md` (the workaround that
  routed the push), `forge-credential-guard-push-channel-gap-2026-07-08.md`,
  `git-mirror-fetch-clobbers-exported-ref-2026-07-12.md`,
  `mirror-pre-receive-openspec-yaml-reject-2026-07-12.md`,
  spec `git-mirror-service`.

## Evidence

In-forge agent ("Big Pickle", meta-orchestration cycle inside the macOS
guest forge, ~22:33–22:36Z) pushed 3 commits (`964d01ae`, `18c10d53`,
`33da90ab`) to `osx-next` via `git://tillandsias-git/tillandsias` after
adding a repo-local insteadOf rewrite. The push:

- succeeded from the agent's perspective (OpenCode announced a successful
  push to remote);
- updated `refs/remotes/origin/osx-next` to `33da90ab` in the shared
  checkout — the strongest possible "it worked" signal to any later reader;
- was NEVER relayed upstream: `gh api repos/8007342/tillandsias/branches/osx-next`
  (bypassing the poisoned git config) showed GitHub still at `a74921f1`
  ~15 minutes later. No error surfaced anywhere the agent or operator
  could see.

Recovery this cycle: insteadOf removed on the host, `git fetch` (forced
tracking-ref correction back to GitHub truth), then a host-side
`git push origin osx-next` delivered `33da90ab` for real (verified via API).

## Why P1

The transparent mirror is the designed push channel for forge agents
(`TILLANDSIAS_HOST_KIND=forge` satisfies the credential-channel guard on
exactly this promise). A mirror that acks and drops turns every forge
cycle's Non-Negotiable Exit Contract into silent data loss: the agent
believes it pushed, the ledger believes it pushed, and the work exists
nowhere durable. This defeats the guard's purpose from the inside.

## Open questions for the fix packet

1. Is relay-to-upstream implemented-but-broken (missing upstream credentials
   in the mirror container — the operator's live hypothesis), asynchronous
   with an unbounded/opaque queue, or not implemented for push at all?
   (Spec `git-mirror-service` + `openspec/litmus-tests/litmus-git-mirror-ref-convergence.yaml`
   should pin whichever answer is chosen.)
2. The mirror MUST NOT return success until upstream relay is durable, OR
   must expose relay state so the credential-channel guard / exit contract
   can verify actual delivery (`git ls-remote` against the mirror is
   insufficient — it reflects the mirror's own refs, which is exactly the
   false signal observed).
3. Note `mirror-pre-receive-openspec-yaml-reject-2026-07-12.md`: the mirror
   pre-receive DID reject an earlier push loudly — so the reject path
   surfaces errors while the accept path loses data silently.

## Repro

From a forge lane with the insteadOf rewrite: commit, `git push origin
<branch>`, observe success + updated tracking ref; then query GitHub
out-of-band — upstream unchanged.

---

## 2026-07-13 — LIVE repro on the first Windows in-forge cycle (relay recovered manually)

- agent windows-yolanda-fable5-20260713T2105Z (host), opencode/BigPickle in-forge
- Forge cycle order 307: commit `a04b8c91` on linux-next, forge push reported
  "Push to git mirror: PASS (GitHub relay via mirror post-receive)" — but
  origin/linux-next stayed at 66d8b134. Mirror acked, relay never happened
  (or the mirror volume was project-scoped and torn down with the lane).
- Host recovery: fetched the commit out of the guest clone
  (`//wsl.localhost/tillandsias/home/forge/src/tillandsias`), verified 1-commit
  fast-forward, pushed manually: 66d8b134 → a04b8c91 on origin/linux-next.
- Confirms this packet (order 318) as the top mirror-ladder priority: an
  unattended forge cycle SILENTLY loses its work without a host-tier babysitter.
  Windows evidence: plan/issues/build-install-smoke-e2e-findings-2026-07-13-windows.md.
