# Git-mirror architecture revamp — operator-directed consolidation of the 2026-07-12 push-channel failures

- Date: 2026-07-12
- Class: research → openspec change (promoted as plan/index.yaml order 315)
- Directive: The Tlatoāni, 2026-07-12 attended smoke: "It's due time we
  revamp the git-mirror architecture."
- Owner spec: `openspec/specs/git-mirror-service/`

## Why now — one day's inventory of push-channel defects

Today's attended macOS smoke plus sibling-host work surfaced, in ONE day:

1. `git-mirror-push-false-success-not-relayed-2026-07-12.md` (P1): mirror
   acks pushes and updates tracking refs but never relays to GitHub —
   silent data loss behind a success signal.
2. `forge-mirror-insteadof-missing-2026-07-12.md` (+ host addendum): no
   baked-in transparent routing, so the in-forge agent hand-wrote an
   insteadOf into the SHARED `.git/config`, breaking all host-side git
   until quarantined.
3. `forge-credential-channel-missing-2026-07-12.md` (Big Pickle #2's
   blocker): `check-credential-channel.sh` returned
   `missing:no-credential-channel` INSIDE the forge — the
   `TILLANDSIAS_HOST_KIND=forge` bypass never engaged (env marker absent
   in the macOS lane?), and per (1) it would have been a false promise if
   it had. Its suggested fix (point origin at the mirror in `.git/config`)
   is the exact host-poisoning move from (2) — in-forge agents cannot see
   that the checkout is host-shared; the architecture must make the safe
   thing the default thing.
4. `mirror-pre-receive-openspec-yaml-reject-2026-07-12.md`: reject path is
   loud while the accept path loses data (asymmetric failure surface).
5. `git-mirror-fetch-clobbers-exported-ref-2026-07-12.md` (linux, fixed
   this cycle): ref-convergence fragility on the fetch side.
6. `forge-credential-guard-push-channel-gap-2026-07-08.md`: the standing
   gap packet this all grew from.

## Design constraints for the revamp (operator-stated + derived)

- QUARANTINE, not share: the host's `github.com` origin config must never
  be visible to (or writable by) the forge. The forge sees ONLY the
  mirror; routing + credentials are injected via forge-scoped environment
  (entrypoint `GIT_CONFIG_GLOBAL` / container-home gitconfig), never the
  shared repo config. Add a guard/litmus that fails loud if a forge agent
  writes url/credential config into the shared `.git/config`.
- Success means DURABLE upstream delivery: the mirror must not ack a push
  until it is relayed upstream, or must expose queryable relay state that
  the credential-channel guard and exit contract verify (mirror-local
  refs are proven insufficient evidence).
- The forge-kind guard bypass must be re-derived from the above: `ok:forge`
  should attest a VERIFIED transparent channel (env marker present AND
  relay state healthy), not a host-kind string.
- Cross-platform: the same model must hold where the checkout is
  host-shared (macOS virtiofs today) and where it is mirror-materialized
  (Linux volumes) — 2's host poisoning is macOS-specific fallout of a
  design that assumed isolation.

## Deliverable

An OpenSpec change proposal revamping `git-mirror-service` (spec deltas +
litmus updates incl. `litmus-git-mirror-ref-convergence`), then staged
implementation packets. Shaping the proposal is the first claimable slice;
pickup on mutable Linux (mirror service is exercised there and the
coordinator owns spec merges).
