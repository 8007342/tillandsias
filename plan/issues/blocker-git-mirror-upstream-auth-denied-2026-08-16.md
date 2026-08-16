# BLOCKER: git mirror upstream write authorization DENIED (403 class) — 2026-08-16

**Status:** blocked · **Owner:** operator · **Class:** 756-2jnj / 759 (seed-time authorization validation)

Observed 2026-08-16 ~10:1xZ during the cycle-4 post-build e2e forge lane
(litmus:opencode-prompt-e2e-shape STEP 5, evidence
`target/build-install-smoke-e2e/*/01-build-install-rerun.log` around line 4030):
the in-forge meta-orchestration cycle's credential-channel guard refused
committable work — the mirror is reachable but its upstream credential is not
currently write-authorized against GitHub. The lane behaved exactly per design:
filed this blocker, refused work, exited without an MO-FULL marker (the missing
marker is the loud failure). FORGE_EXIT=127 from the launcher.

**Smallest next action (operator):** repair the mirror's Vault GitHub token /
its repo push permission, then re-run `images/git/probe-upstream-auth.sh` (or
any forge launch) to republish a fresh `authorized` verdict ref.

**Provenance note:** the in-forge original of this file was committed inside
the ephemeral forge checkout and could not be pushed (the 403 it reports), so
it died with the container; it reached the host only because the litmus
launcher captured stdout. Cross-referenced as live evidence on 741-3y48.

## Update 2026-08-16T20:24Z — verdict variant: `blocked:upstream-auth-unpublished`

A second forge cycle hit the credential-channel guard at 20:24Z, this time
with a **different** verdict: the mirror publishes NO
`refs/tillandsias/upstream-auth/*` ref at all (`blocked:upstream-auth-unpublished`,
not the morning's `denied` 403). Reads over `git://git-dejpgkh1q5b47s5tureg`
work (heads list, `git fetch`), so forge→mirror is reachable; the mirror's
probe (`images/git/probe-upstream-auth.sh`, published every
`MIRROR_RECONCILE_INTERVAL`=120s tick per `images/git/entrypoint.sh`) is
either not running in the live container or the container image predates
order 756-2jnj. This means upstream write authorization is **unproven**, not
confirmed-denied. The cycle refused worker drain per the guard, updated this
blocker, and pushed it (or reproduced it in the handoff if the push also
failed — check git history for this file).

**Smallest next action (operator, unchanged):** restart/rebuild the
`tillandsias-git` mirror container so its probe runs and republishes a fresh
`authorized` verdict ref, or repair the Vault GitHub token / repo push
permission if the probe reports `denied`. Re-run `images/git/probe-upstream-auth.sh`
(or any forge launch) to verify.

## Update 2026-08-16T20:27Z — the credential WORKS; only verdict publication is broken

The blocked cycle's sanctioned blocker push (commit `e1585de61`) **succeeded
through the mirror relay**: `[relay] Atomic push to
https://github.com/8007342/tillandsias.git succeeded` +
`[pre-receive] Relay verified: upstream durably accepted the ref transaction`,
and `git ls-remote` converges on the pushed head. The mirror→upstream Vault
credential is therefore write-authorized RIGHT NOW — the morning's `denied`
403 was transient or has since been repaired (e.g. token rotation).

So the remaining defect is NOT the credential. It is that the mirror publishes
NO `refs/tillandsias/upstream-auth/*` verdict ref (re-checked 20:27Z, guard
still `blocked:upstream-auth-unpublished`), so the fail-closed guard blocks
every forge cycle's worker drain even though pushes would succeed. The live
`tillandsias-git` container appears to predate order 756-2jnj or its probe
loop is not running.

**Smallest next action (operator, narrowed):** restart/rebuild the
`tillandsias-git` mirror container so `probe-upstream-auth` starts publishing
verdict refs (verify: `git ls-remote <origin> 'refs/tillandsias/upstream-auth/*'`
shows an `authorized/<epoch>` ref). No token repair is needed unless the probe
reports `denied`. Until then, every forge cycle will fail-closed at this gate
while still being able to push — a guard-infrastructure defect, tracked here.

## Update 2026-08-16T21:12Z (linux_mutable) — root class identified; self-serviceable

macuahuitl's cycle-4 evidence closes yoga's open question: our stack was
CREATED FRESH during the post-build smoke and still hit
`blocked:upstream-auth-unpublished` — so the probe absence is not container
age. The probe wiring EXISTS in current images/git sources (entrypoint
run_auth_probe post-sweep + every reconciler tick); the running containers
were served from a stale IMAGE predating 756-2jnj because the on-demand
image ensure keys on VERSION tag alone — the 702-griq class, now with a
fleet-scale specimen (event recorded there).

**No operator action required.** Remedy on each host: rebuild the git image
at the installed VERSION (`scripts/build-image.sh` git lane or the next
`--ci-full`), recreate the stack, verify
`git ls-remote <origin> 'refs/tillandsias/upstream-auth/*'` shows
`authorized/<epoch>`. The macuahuitl overnight loop (2026-08-16→17) owns this
lane tonight.

## Update 2026-08-16T21:5xZ (linux_mutable) — verdict machinery LIVE; credential genuinely denied

The rebuilt tillandsias-git image (v0.4.260815.1, probe wiring baked) was
proven end-to-end by a direct forge lane: the fresh mirror now PUBLISHES
verdict refs (observed `denied/1786914963`, refreshed every ~120s tick), the
credential guard reported `blocked:upstream-push-unauthorized` on a FRESH
verdict, the in-forge cycle refused worker drain, three sanctioned push
attempts were rejected by the pre-receive relay, and no MO-FULL marker was
emitted. Every layer of 756-2jnj behaved exactly as designed.

CONCLUSION SHARPENED: the 702-griq stale-image half is FIXED on this host
(verdicts publish); what remains is the credential itself — the mirror's
Vault GitHub token is refused upstream RIGHT NOW. Yoga's 20:27Z push success
was a single earlier good epoch (intermittent authorization — token expiry,
fine-grained scope, or upstream rate/permission flapping are the candidates).

**Operator action (the only remaining one):** repair/re-seed the mirror's
Vault GitHub token push permission for 8007342/tillandsias, then verify
`git ls-remote <origin> 'refs/tillandsias/upstream-auth/*'` shows
`authorized/<epoch>`. The in-forge original of this update (commit fb4206bdf)
died with its container, per the standing 741-3y48 shape; salvaged here from
the launcher-captured output.
