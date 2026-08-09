# Git mirror zero-trust audit — 2026-08-05

## Verdict

The current write boundary is unauthenticated, and the relay makes the blast
radius larger than "mirror-local refs." Any enclave peer can reach anonymous
`git://` receive-pack and create or fast-forward arbitrary refs while the mirror
authenticates upstream with its privileged Vault-backed credential. At audit
time it could also delete upstream refs in repeatable batches; order 579's
containment below now rejects deletion before relay.

Network placement limits reachability but is not identity. This conflicts with
the operator's zero-trust requirement and with NIST's zero-trust model. Git's
own daemon documentation describes receive-pack as unauthenticated and suitable
only when every peer is trusted:

- <https://git-scm.com/docs/git-daemon.html>
- <https://csrc.nist.gov/pubs/sp/800/207/final>

## Reproduced code path

- `images/git/entrypoint.sh` starts `git daemon` on `0.0.0.0:9418` with
  `--enable=receive-pack`.
- At audit time, `images/git/relay-refs.sh` converted a zero new object ID
  directly into an upstream deletion refspec and rejected only transactions
  containing more than ten deletions, so repeated batches bypassed the guard.
- The same relay then pushes the supplied refspecs atomically with the mirror's
  upstream credential.
- At audit time, deletions bypassed content validation and fresh repositories
  configured `receive.denyDeletes=false` / `receive.denyNonFastforwards=false`;
  existing volumes skipped configuration inside the fresh-init branch. Order
  579 replaces that behavior below. New branch grammar remains warning-only.
- A successfully relayed malicious fast-forward can later be consumed by clean
  host auto-sync.

GitHub branch protection may reject selected refs, but an external service's
configuration is not this boundary's authorization layer.

The active litmus named `git-mirror-no-anonymous-daemon-write` certifies the
wrong property: it explicitly accepts anonymous enclave writes and uses source
greps rather than a negative unauthenticated push.

## Existing ownership

Do not file another generic authentication packet:

- 322 owns the authenticated transport decision and is ready.
- 451 owns implementation and is blocked on the unsigned decision.
- 579 owns existing-volume repository hardening.
- 319/390 own the GitHub App decision/implementation for the separate upstream
  one-hour, repository-scoped credential.
- 424 owns the current Vault Agent/credential-helper lifecycle, not client
  authentication.

The draft SSH-CA decision is the right transport family: OpenSSH certificates,
host certificates, short TTLs, and a per-lane `ssh-agent` signing sidecar give
Git-native authentication without putting a private key in the forge. Primary
references:

- <https://developer.hashicorp.com/vault/docs/secrets/ssh/signed-ssh-certificates>
- <https://developer.hashicorp.com/vault/docs/concepts/policies>
- <https://man.openbsd.org/sshd_config>

## Corrections required before signing the SSH-CA design

1. The sample Vault policy `ssh-client-signer/sign/*` is cross-project
   authority. A project-A sidecar could request a project-B certificate. Mint
   an exact per-project AppRole/policy and bind it to one opaque project ID.
2. Shared aliases `git-service` / `tillandsias-git` also collapse host identity.
   Use a unique opaque per-project hostname plus exact host-signing role and
   certificate principal; prove two simultaneous projects cannot cross-route.
3. The latest zero-trust direction makes authenticated reads part of closure.
   Move upload-pack and receive-pack to the forced SSH wrapper, then remove git
   daemon entirely after parity. A missing agent socket must fail without a
   `git://` fallback.
4. Persist Vault audit records. `/vault/audit` currently dies with container
   recreation, defeating attribution and incident response.
5. The mirror is dual-homed directly to egress although the enclave spec says
   only the proxy is dual-homed. Route upstream Git via the proxy, or ratify a
   narrow exception with enforced destinations and a negative bypass test.

The user direction resolves per-lane ephemeral identity and automatic rotating
TTL. CA rotation authority/cadence still needs an explicit durable decision;
this audit does not forge a signature for it.

## Smallest safe v0.5 sequence

1. Amend and sign 322 with authenticated read/write, exact per-project client
   and host policies, unique service identity, TTL renewal, and fail-closed
   behavior. Add 579 and the cross-project identity packet as prerequisites of
   451.
2. Deploy and live-verify the implemented order-579 containment:
   `denyNonFastForwards=true`, `denyDeletes=true`, and `fsckObjects=true` now
   apply on every start and the existing-volume fixture is bound. This contains
   ref deletion/branch-rewind risk but does not authenticate the boundary.
3. Prove non-root `sshd` in the actual git image under `--read-only`,
   `--cap-drop=ALL`, uid 1000, high port 2222 before production wiring.
4. Prove project A cannot sign for or connect to project B, and persist audit.
5. Migrate one lane behind a flag; exercise authenticated clone/fetch/push,
   expiry, automatic re-sign, and missing-socket refusal.
6. Flip all lanes, remove port 9418/git-daemon, and replace the misleading
   litmus with live negative cases.

New non-duplicate packets:

- `git-mirror-cross-project-service-identity`
- `git-mirror-egress-network-spec-drift`

## Containment implementation — order 579 (2026-08-06)

The smallest pre-authentication containment slice is now implemented:

- every entrypoint start applies `receive.denyNonFastForwards=true`,
  `receive.denyDeletes=true`, and `receive.fsckObjects=true`, including named
  volumes created by an older image;
- pre-receive rejects every ref deletion and non-fast-forward branch updates
  before the privileged upstream relay runs, closing the reproduced ordering
  bug where upstream changed and the mirror then rejected locally;
- `scripts/test-git-mirror-existing-volume-hardening.sh` runs the exact
  entrypoint setup path twice against a permissive existing bare repository,
  instruments relay invocation, compares complete ref snapshots, proves
  branch/tag/custom/mixed deletions and branch rewind are non-mutating, proves
  stale old IDs, non-canonical/invalid refs, and non-commit branch tips stop
  before relay, proves the relay helper independently refuses deletion and
  whitespace-smuggled delete/`--force` argv, exercises derived SHA-256 zero-ID
  handling, and proves a valid fast-forward still converges both repositories.

This immediate validation does not prove that every native receive-pack check
or ref-lock race has been reproduced before relay. P0 packet
`git-mirror-pre-receive-native-validation-relay-gap` (610-txvr) owns replacing
that open-ended equivalence assumption with a transaction boundary that cannot
mutate upstream and then lose the local decision.

This does not authenticate port 9418. Anonymous enclave peers can still create
and fast-forward refs and thereby use the mirror's upstream authority. The
active spec and the historically named
`litmus:git-mirror-no-anonymous-daemon-write` now state that limitation instead
of describing network placement or the service's Vault credential as client
identity.

The all-ref-delete policy intentionally conflicts with ready orders 502/504,
whose proposed lane-exit/garbage-collection flows delete `agent/*` branches.
Those flows must depend on a future authenticated, policy-authorized deletion
mechanism; they must not reopen anonymous branch deletion to satisfy their
current design. The former ten-delete threshold and
`TILLANDSIAS_ALLOW_BULK_DELETE` escape hatch are intentionally superseded.
