# Host-credentialless push via a local git mirror — design summary for ruling

- filed: 2026-09-19 by lenovinha-silverblue
- for: macuahuitl-fedora (fleet-wide, touches the push lane every host depends on)
- origin: operator proposal, 2026-09-19, after the gnome-keyring 50.0 investigation
- related: 1265-8qr6 (probe removal), 1189-2ra5 (credential discriminator),
  1118-bscs (helper host allowlist), and the upstream row
  `gnome-keyring-50-aborts-on-a-secret-service-property-get-2026-09-19.md`

## The premise

**The host holds no GitHub credential. The mirror does, from Vault.** Host work
pushes to a local `tillandsias-git-mirror` container, which relays to GitHub
using a token it reads from Vault at push time. Nothing on the host reads the
Secret Service on the hot path, so the upstream abort cannot cost us a push.

The operator's second argument is the stronger one: **we become users of our own
infrastructure.** A mirror service whose only users are hypothetical does not get
its rough edges found. Every Linux host already has idempotent creation scripts.

## What already exists — this is a WIRING job, not a new mechanism

- HashiCorp Vault in-enclave: `crates/tillandsias-vault-client/`,
  bootstrapped by `crates/tillandsias-headless/src/vault_bootstrap.rs`,
  AppRole-minted per-container tokens. Spec `openspec/specs/tillandsias-vault/`
  already names this exact credential: "starting with the GitHub token at
  `secret/github/token`".
- A real gitcredentials(7) helper answering from Vault:
  `images/git/git-credential-tillandsias.sh`, fail-closed host allowlist
  (1118-bscs), `store`/`erase` deliberate no-ops because Vault owns the secret.
- The relay itself: `images/git/relay-refs.sh` — refname validation, a
  refspec-injection guard, a pre-push staleness fetch that deliberately does NOT
  advance exported heads, and a `litmus:git-mirror-relay-verified-ack`.
- Vault Agent auto-auth in the mirror: `images/git/vault-agent.hcl`,
  `vault-agent-bootstrap.sh`.
- On lenovinha the container is PROVISIONED BUT DORMANT: `tillandsias-vault`
  Exited (143) three days ago; TLS material and the git-mirror AppRole secret
  still present from 7-8 days ago.

## What is missing — the operator named both correctly

### 1. Vault has no GitHub credential LIFECYCLE

Measured 2026-09-19: `--github-login` is the ONLY flag in the tree. There is no
`--github-status`, `--github-refresh`, `--github-logout`. A store you can write
and never inspect, renew or revoke is not a lifecycle; it is a drop box. This
needs investigation before design — in particular whether refresh is a token
exchange or a re-login, and what logout must guarantee (revocation at GitHub, or
only local erasure — they are different promises and only one is honest).

Note the existing `1188-vixu` order — clear-vault-credentials partial clear
exits zero — is evidence this surface is already under-specified.

### 2. The hooks must be TRANSPARENT and ATOMIC, with hard failures

Operator's requirement, and the correct one: a mirror that is sometimes a mirror
is worse than no mirror. Requirements:

- **Actionable affordances.** Every refusal names the remedy, in the caller's
  terms. A relay that fails must say what to run, not what went wrong.
- **FAIL HARD.** No silent degradation to a direct push, no partial relay that
  reports success. A half-relayed push is the failure mode that would make this
  whole design a liability.
- **Atomic.** Either every ref in the push reaches GitHub or none does, and the
  local state after a failure equals the state before it.

## The consequence nobody should discover later

**It inverts the credential guard's premise.** Today
`missing:no-credential-channel` means "this host is broken". On a mirror-routed
host it is THE CORRECT STEADY STATE, and `scripts/check-credential-channel.sh`
would red every cycle on a host working exactly as designed.

The guard needs a notion of a host that DELEGATES credentials, and what it
verifies becomes *can I reach my mirror, and does its relay work* rather than
*do I hold a token*. This is the one child that cannot be hand-waved, and it
should be filed as its own packet.

## The gate is NOT bypassed — checked, with one thing to verify

`scripts/hooks/pre-push-local-gate.sh` is a git pre-push hook on the host repo,
so it fires on the host->mirror hop whatever the remote is named. Stamp
discipline survives; the mirror->GitHub hop then adds its own layered checks. So
this path is MORE defended than the host's, not less.

TO VERIFY AT IMPLEMENTATION TIME: whether that hook is conditional on the remote
being named `origin`. If it is, that single line silently turns the mirror into
a gate bypass. Cheap to check, catastrophic to miss.

## Named costs, so the ruling is made with them

- **A container on the push path.** Today a push needs `gh` + an unlocked
  keyring; afterwards it needs the Vault and mirror containers up. We trade a
  failure we do not control (an upstream daemon that aborts on a race) for one
  we do. Better — ours is diagnosable — but it IS a trade, and lenovinha's vault
  being down for three days is exactly the shape of the new failure.
- **Not a keyring escape.** Vault's auto-unseal is anchored in the OS keychain
  (`native-secrets-store`, `vault-shamir-share-v1`). This is ONE read per boot
  instead of one per push and per `gh` call. Orders of magnitude against a race
  is a real win; stating it as removal would be believed and then disproved by
  the next abort.
- **The guard redesign** above.

## Deliberately kept

The keyring path stays wired as a failsafe, with its fixtures intact. A host
must be able to fall back, and keeping the arms keeps 1189-2ra5 and the
credential-channel fixture meaningful rather than deleted.

## The dogfooding claim, stated so it can be checked

The expectation is falsifiable: being active users should SURFACE MIRROR BUGS.
If six weeks of fleet use surfaces none, the claim was decoration and should be
recorded as such. Record the ones it actually surfaces.

## Also relevant: the host's push path got WORSE today

`gh auth setup-git` wrote
`credential.https://github.com.helper=!/usr/bin/gh auth git-credential`, so every
host push now shells out to `gh`, which reads the keyring. Secret Service
traffic on the push path went UP today. That is the call this design replaces.
