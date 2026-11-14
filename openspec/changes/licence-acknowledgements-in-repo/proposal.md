## Why

Operator ruling 2026-11-11: licence acceptances are committed into the
project repository, verifiable by exploring commit history, and a vault wipe
must never lose them. Today the `accept-licence` skill already commits a record
to `licences/acknowledgements/<slug>.yaml` in the agreeing project, but the
restricted-fetch gate does not read it there. It reads a copy under
`<state dir>/licence-acknowledgements/<project>/` (1958-fc3y), and
`licence_consent::Verifier::for_host` verifies signatures against
`<state dir>/approvals/allowed_signers`. Both live outside the repository: a
state reset or a vault rebuild (vault-is-thrown-away-not-recovered) loses
either the copy or the signer, and a valid, committed acceptance then reads as
absent.

This also answers open question OQ-19 of the 2026-11-11 blind-design exercise
with option (a): a wipe makes a new key, and records signed with the old key
stay valid against the public key already committed.

## What Changes

- The record of truth is `licences/acknowledgements/<slug>.yaml` in the
  project repository (the operator's "e.g. ./licenses/" names this folder; the
  existing British spelling `licences/` is kept so the four seeded records and
  the skill do not move).
- The project's approved signer public keys are committed at
  `licences/allowed_signers` (ssh-keygen allowed-signers format). Adding a
  signer is its own commit.
- The gate reads records from the project's git (its mirror) at the commit it
  is asked about, not from a state-dir copy. The state-dir copy is removed.
- A record is valid when its signature verifies against the signer set as it
  stood in the commit that added the record, the commit that added it is
  reachable from the project's integration branch, and it is within its expiry.
  Removing a signer later never invalidates a record added while it was listed.
- A one-shot migration commits any state-dir-only record into its project.
- Every obligation holds independently on Linux, macOS and Windows.

## Impact

- `licence_consent` (Verifier, admits_restricted path), `restricted_fetch`.
- `skills/accept-licence/SKILL.md` step 4 drops the state-dir copy and adds the
  signer commit.
- Packets: 2080-qqsm (gate reads git), 2081-qndc (history-anchored
  verification), 2080-ryc8 (migration). Related: 1956-ecpb, 1958-fc3y,
  1958-22yh, 1954-dvz9.
