## ADDED Requirements

### Requirement: enrollment is gated by both operator logins and nothing else

`tillandsias fleet enroll` SHALL require a stored GitHub bundle whose
`GET /user` id equals `github_user_id` in `plan/fleet/owner.yaml` and a
stored Cloudflare bundle whose user id hashes (salted SHA-256) to
`cloudflare_user_sha256`; the first enrollment SHALL write both pins. On any
mismatch or absence it SHALL refuse with
`refused:fleet:not-owner:<github|cloudflare>` and SHALL mint no key. On
success it SHALL mint the announce key into the host's own Vault, ensure the
host's ssh CA mounts and Noise static, and emit `plan/fleet/peers/<host>.yaml`
on a work ref.

#### Scenario: a wrong GitHub owner mints nothing

- **WHEN** `fleet enroll` runs with a GitHub bundle whose user id differs from the pin
- **THEN** stderr is `refused:fleet:not-owner:github` and Vault holds no `secret/fleet/announce`

### Requirement: connection-time trust is the pinned CA, never a live login

Host-to-host connections (SSH, git mirror, experts) SHALL be authenticated
only by certificates issued by the peer's own Vault CA whose public key is
pinned in that peer's landed record. No connection path SHALL consult a
GitHub or Cloudflare token or the rendezvous. A peer SHALL be trusted only
after its record is on linux-next, never because it appears in the roster.

#### Scenario: a lapsed token breaks nothing

- **WHEN** the GitHub and Cloudflare bundles on both hosts are expired and the rendezvous is unreachable
- **THEN** `ssh <peer>.fleet.tlatoani.net` with `StrictHostKeyChecking=yes` and an experts query to the peer both succeed

#### Scenario: an announced but unlanded host is not trusted

- **WHEN** a host appears in the roster but has no record under `plan/fleet/peers/`
- **THEN** its host certificate is refused and no trust file names it

### Requirement: each host's CA vouches only for that host

Rendered client trust SHALL contain one `@cert-authority` line per admitted
peer restricted to `<host>.fleet.tlatoani.net,<host>.mesh.fleet.tlatoani.net,<host>.local,<host>`
with that peer's host-CA key. The fleet sshd SHALL run rootless on port
48622 with `AuthorizedKeysFile none`, `TrustedUserCAKeys` = admitted user-CA
keys, and `AuthorizedPrincipalsCommand tillandsias fleet principals %F %u`
printing only the principals the tree grants to the CA `%F`. Host
certificates SHALL last 7 days and renew at 3 days left; user certificates
16 hours with principal `til:fleet-operator:<login>`.

#### Scenario: a CA cannot vouch for another host's name

- **WHEN** host C's CA signs a host certificate for B's name and C serves it
- **THEN** the client refuses the connection to B

#### Scenario: a CA cannot assert a principal the tree did not give it

- **WHEN** a user certificate from C's CA asserts `til:fleet-mirror:B`
- **THEN** sshd refuses it and logs the principal mismatch

### Requirement: removal of the record is the revocation

`tillandsias fleet leave` and the logouts SHALL remove the host's record on a
work ref; every online host SHALL re-render its trust files and KRL from the
tree within one renew period of fetching the removal. A revoke notice relayed
by the rendezvous, signed by a non-revoked admitted key, SHALL suspend the
named CA for new sessions until the tree confirms or 24 h pass.

#### Scenario: a removed host is refused after the next fetch

- **WHEN** C's record is removed and the other hosts fetch linux-next
- **THEN** the next connection from C is refused with the KRL reason in the sshd log
