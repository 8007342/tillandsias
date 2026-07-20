# RESEARCH: restore authenticated forge→mirror writes — eliminate the unauthenticated daemon receive-pack path (2026-07-19)

- **Class**: research (MANDATORY before implementation, operator standing rule)
- **Owner host**: linux
- **Desired release**: v0.5 (NOT v0.4 — v0.4 ships with the interim unblock)
- **Research packet**: order 322 (ladder rung E) — this doc is its focused
  appendix; the implementation packet is order 451 (blocked on this decision).
- **Related**: order 450 (the interim unblock this restores), order 423 (removed
  both anon write paths), order 322 (the existing research-first rung).

## Operator directive (2026-07-19)

> We'll preserve that as a feature for a future release, we really don't like to
> allow for unauthenticated writes, even within the forge. So we'll unblock it
> for now, but file research and work packets to restore it properly in a future
> release.

This is a **decision**, not an open question, and it changes order 322's shape:

- The interim state (order 450: `git daemon --enable=receive-pack` on the
  enclave-internal :9418, gated only by the pre-receive relay + network topology)
  is **explicitly temporary** and ratified ONLY as a v0.4 unblock.
- The "explicitly accept-risk for git:// with topology invariants pinned by
  litmus" branch of order 322's exit criteria is now **OFF THE TABLE**. The
  operator does not accept an unauthenticated write path even on the isolated
  enclave. Order 322 collapses to: choose an authenticated transport and migrate.
- End state: the daemon serves **fetch/upload-pack only**; every push is
  authenticated at the transport, with a per-forge identity so pushes are
  attributable. git:// receive-pack is removed again once the authenticated path
  is live and parity-verified.

## Why the interim is tolerable for v0.4 (the risk we are temporarily accepting)

Recorded so the future work knows exactly what it is closing:

- The daemon is on an `--internal` podman network with no internet route; the
  only clients are the operator's own forge agents.
- The real GitHub-auth boundary — the pre-receive relay (Vault-held token, no
  `--mirror/--all`, bulk-delete guard) — is unchanged, so a rogue enclave push
  cannot rewrite or destroy upstream.
- Residual risk being accepted: any process that reaches the enclave daemon can
  push to the **local mirror** with no identity and no attribution, and could
  delete/rewrite mirror-local refs (not upstream). Multi-tenant forges (several
  agents/users on one enclave) make "no attribution" the sharp edge.

## Design space (the research to complete before order 451 implements)

1. **Transport choice.** Three candidates, pick with a threat-model rationale:
   - **Authenticated smart-HTTP** over the mirror (git-http-backend behind an
     auth-checking front). lighttpd was in the image historically (removed in
     423); evaluate a minimal auth module vs. a small purpose-built receive
     endpoint. Pre-receive gating and ff-denial already exist server-side.
   - **SSH** with a per-forge keypair (forge identity = its pubkey). Heavier
     (sshd in the mirror image, key distribution) but the most standard
     authenticated git push transport.
   - **mTLS** on a git-over-HTTPS endpoint, per-forge client cert minted at
     launch from Vault. Composes with the existing Vault issuance path.
2. **Per-forge identity issuance.** Where the credential comes from (Vault
   AppRole per forge? short-lived, launch-scoped) and how it reaches the forge
   WITHOUT landing in the agent's curious hands (cf. the operator's "vault
   container outside agents' hands" directive — the credential should be
   injected at the transport layer, not readable as a file in the forge).
3. **Attribution.** The pre-receive relay should log WHICH forge identity pushed
   which refs, so a bad push is traceable to an agent/lane.
4. **Migration + parity.** One lane migrated behind a flag first, with a
   fetch/push parity fixture (push over the authenticated transport reaches
   upstream through the relay exactly as git:// did), then flip the default and
   remove `--enable=receive-pack` from the daemon.
5. **Fetch stays anonymous-read.** git:// `--export-all` upload-pack (clone/
   fetch) is fine to keep unauthenticated on the enclave — this work is about
   the WRITE path only. Confirm nothing depends on git:// for writes after
   migration.

## Deliverable of the research (order 322)

A decision record: the chosen transport with threat-model rationale, the
per-forge credential-issuance design, the attribution mechanism, and the
smallest migration rungs — Tlatoāni sign-off required (contested-practice flag
from the enterprise cheatsheet) before order 451 implements.

## Non-goals

Not re-touching the pre-receive relay's upstream-auth (that boundary is correct
and unchanged). Not ZeroClaw / agent↔agent messaging. Not the git:// read path.
