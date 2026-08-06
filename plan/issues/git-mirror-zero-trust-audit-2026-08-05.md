# Git mirror zero-trust audit — 2026-08-05

## Verdict

The current write boundary is unauthenticated, and the relay makes the blast
radius larger than "mirror-local refs." Any enclave peer can reach anonymous
`git://` receive-pack, create or fast-forward arbitrary refs, and delete
unprotected upstream refs in repeatable batches while the mirror authenticates
upstream with its privileged Vault-backed credential.

Network placement limits reachability but is not identity. This conflicts with
the operator's zero-trust requirement and with NIST's zero-trust model. Git's
own daemon documentation describes receive-pack as unauthenticated and suitable
only when every peer is trusted:

- <https://git-scm.com/docs/git-daemon.html>
- <https://csrc.nist.gov/pubs/sp/800/207/final>

## Reproduced code path

- `images/git/entrypoint.sh` starts `git daemon` on `0.0.0.0:9418` with
  `--enable=receive-pack`.
- `images/git/relay-refs.sh` converts a zero new object ID directly into an
  upstream deletion refspec. It rejects only transactions containing more than
  ten deletions, so repeated batches bypass the guard.
- The same relay then pushes the supplied refspecs atomically with the mirror's
  upstream credential.
- Deletions bypass content validation; new branch grammar is warning-only.
- Fresh repositories configure `receive.denyDeletes=false` and
  `receive.denyNonFastforwards=false`; existing volumes do not receive future
  hardening because configuration is inside the fresh-init branch.
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
2. Execute 579 first: apply `denyNonFastForwards=true`, `denyDeletes=true`, and
   `fsckObjects=true` on every start, with an existing-volume upgrade fixture.
   This contains deletion/rewind risk but does not authenticate the boundary.
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
