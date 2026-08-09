# Git mirror relay can succeed before a later native receive rejection

- **Date discovered**: 2026-08-06 UTC
- **Desired release**: v0.5
- **Severity**: P0 security/integrity
- **Area**: git mirror receive transaction / upstream relay
- **Packet**: `git-mirror-pre-receive-native-validation-relay-gap`

## Outcome

Replace the current inference that a successful `pre-receive` relay guarantees
the mirror will accept the same transaction. The final design must make an
upstream mutation impossible when Git later rejects or loses the local ref
transaction, while retaining one truthful client acknowledgement and atomic
multi-ref behavior.

## Reproduction

Order 579 exposed the original class: Git invoked the mirror's `pre-receive`
relay, the upstream deletion succeeded, and only afterwards
`receive.denyDeletes=true` rejected the local transaction. Adding deletion and
branch-rewind checks closes those destructive cases but does not close the
general ordering gap.

Two additional adversarial `git receive-pack --stateless-rpc` probes used the
production pre-receive hook and a relay spy:

1. The request supplied a stale/fabricated old OID `A`; the actual mirror head
   was `C`; proposed `B` was a fast-forward from `A`. The hook printed `Relay
   verified`, then native receive rejected the local update because the ref was
   at `C`, not `A`.
2. The request supplied an invalid refname containing a space. The hook printed
   `Relay verified`, then native receive rejected the refname.

In each shape, the privileged upstream can change while the mirror remains
unchanged. Validating the actual old OID and `git check-ref-format` inside
pre-receive is necessary immediate defense, but it still reimplements only two
of Git's possible later decisions and cannot remove races between validation,
relay, and local ref locking.

## Authoritative semantics

Git's `git-receive-pack` documentation states that `pre-receive` runs before
fast-forward checks, and that objects remain quarantined until the hook
finishes:

- <https://git-scm.com/docs/git-receive-pack#_pre_receive_hook>
- <https://git-scm.com/docs/git-receive-pack#_quarantine_environment>

The same manual says a successful `update` hook is only a prerequisite and does
not ensure the ref is actually updated. Git's `reference-transaction` hook is a
candidate boundary because its `prepared` state has queued and locked refs and
can still abort, but it runs for all Git ref transactions, so receive-only
selection, recursion, quarantine/object visibility, and internal fetch/reconcile
updates must be proven rather than assumed:

- <https://git-scm.com/docs/githooks#_reference_transaction>
- <https://git-scm.com/docs/git-update-ref#_description>

Other valid designs may stage the transaction in a separate repository, make
the authenticated upstream authoritative and update the cache afterwards, or
replace the anonymous relay path entirely. The choice belongs to the packet;
patching an open-ended list of native checks does not satisfy it.

## Required work

1. Enumerate every native rejection or race that can occur after pre-receive,
   including stale old OIDs, invalid/hidden/conflicting refs, lock contention,
   duplicate/malformed updates, object-format differences, and concurrent
   updates.
2. Select and specify a transaction primitive that cannot report upstream
   durability and then fail the local decision silently.
3. Keep internal startup fetch/reconcile and ordinary local maintenance from
   accidentally invoking the privileged upstream relay.
4. Preserve explicit refspecs, no `--mirror`/`--all`, atomic multi-ref upstream
   behavior, fail-closed credentials, and honest client acknowledgements.
5. Update the active git-mirror spec and the order-318 verified-ack claims so
   they describe the property actually demonstrated.

## Exit criteria

- stale/fabricated old-OID, invalid refname, hidden-ref, namespace-conflict, and
  concurrent-update fixtures cannot mutate upstream when the mirror rejects;
- SHA-1 and SHA-256 repositories both derive and validate their native null OID
  and accepted update grammar;
- an allowed single-ref and atomic multi-ref update converge mirror and
  upstream, while every injected failure yields one truthful client failure;
- the chosen boundary is exercised with the production hook/install path and
  proves internal fetch/reconcile/local maintenance cannot trigger a relay;
- active spec, litmus, and plan evidence stop equating `pre-receive` relay
  success alone with inevitable local commit.
