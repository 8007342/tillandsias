## Context

Records today: `tillandsias-licence-acknowledgement v1` statements signed in
the `tillandsias-approval@v1` namespace, stored as YAML with `statement: |` and
`signature: |` block scalars, `expiry` and `signed_at` double-quoted. Four seed
records live in `licences/acknowledgements/` of this repository.

## Decisions

### D1. Layout

```
licences/
  allowed_signers              # ssh-keygen allowed-signers lines, one per approval key
  acknowledgements/<slug>.yaml # unchanged v1 record format
```

`<slug>` stays one record per licence TEXT. No new record version is needed;
the gate change is where the record is read from and what it verifies against.

### D2. Verification is anchored in history

For a record at path `p` the gate finds `A = the commit that added p`
(`git log --diff-filter=A --format=%H -- p`, oldest), reads
`licences/allowed_signers` at `A`, and verifies the signature with
`ssh-keygen -Y verify -n tillandsias-approval@v1` against that file (in Rust,
through the existing `licence_consent` verifier, taking the signer bytes as
input instead of a host path). `A` must be reachable from the integration
branch the fetch is for. A record modified after `A` is invalid (records are
immutable; a renewal is a new file).

Why: the history is the durable record (ruling); anchoring at `A` lets a
signer be rotated after a vault wipe without re-asking the user (OQ-19 a).

### D3. Signer enrolment is a commit

When the host enrols a new approval key (FIDO2 on Linux per 2026-11-11 ruling,
Touch ID on macOS, Windows Hello), `accept-licence` commits its public line to
`licences/allowed_signers` before the first record that uses it. A signer line
that appears in the same commit as a record it signs is refused: a forge must
not be able to add a key and a record in one step. The signer commit itself
needs an OS-verified approval through the approval gates.

### D4. Where the gate reads

The host gate receives a project label; it reads from that project's mirror
(`/srv/git/<project>` in the enclave), which exists on every platform and on a
Pi-fleet mirror holder (multi-machine ruling 2026-11-11). No state-dir copy.

### D5. Migration

On first run after upgrade, each `<state dir>/licence-acknowledgements/<project>/*.yaml`
not present byte-identically in the project repo is committed there in one
commit per project, together with the signer line it verifies against today;
unmatched projects are reported, not deleted. The state-dir directory is
removed only after every record is found in git.

## Risks

- A project without a mirror cannot admit restricted fetches: acceptable,
  the fetch is refused with a named reason.
- `git log` cost per fetch: cache by (record blob id, A) in memory only.
