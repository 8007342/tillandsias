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

## Update 2026-08-17T05:27Z (forge, linux-next) — verdict refs STILL absent

Credential channel guard: `blocked:upstream-auth-unpublished`. Direct probe
confirms zero `refs/tillandsias/upstream-auth/*` refs on origin — the verdict
machinery is absent again, not just stale. The 702-griq remediation (rebuild
git image at installed VERSION + recreate stack) has not reached this forge's
container, or the container was rebuilt from a pre-756 image. Cycle refused
worker drain per the guard; no MO-FULL marker will be emitted.

The git image is at VERSION 0.4.260815.1 (per startup context), same as the
build that had the probe wired — so either the entrypoint's probe loop is not
running, or the container was launched without the reconcile tick. This is the
702-griq class manifesting as persistent infrastructure debt.

**Smallest next action (operator, unchanged):** rebuild the `tillandsias-git`
container image (`scripts/build-image.sh git lane` or `--ci-full`), recreate
the stack, verify `git ls-remote <origin> 'refs/tillandsias/upstream-auth/*'`
publishes `authorized/<epoch>`. Every forge cycle will continue to fail-closed
at this gate until the probe publishes.

## Update 2026-09-03T07:00Z (esmeraldinha forge, WSL2) — machinery PROVEN GOOD, credential still denied

Supersedes the 2026-08-17T05:27Z "verdict refs STILL absent" entry AND the
"smallest next action" above it, which told the operator to rebuild the
`tillandsias-git` image. That rebuild is now known to be unnecessary on this
host: the machinery works and the only broken thing is the token. Measured by
esme-tillandsias-wsl2 and landed here by macuahuitl, because that host cannot
push — which is itself order 982-sguu.

Regime: esmeraldinha, N100/WSL2 forge, v56.9.2.1, mirror
`git://git-o31ujllgc1il9hv1oiig/tillandsias`.

VERDICT MACHINERY IS HEALTHY HERE — the 702-griq stale-image half is fixed on
this host. `refs/tillandsias/upstream-auth/denied/permission/1788418668` was 48
SECONDS old when read; `scripts/check-credential-channel.sh` printed
`blocked:upstream-push-unauthorized` and exited 1 (true exit code, not a
pipeline's). No diagnostic surface misreports: the container HEALTHCHECK is
green throughout, but it is `nc` against the daemon port, scoped and documented
as daemon readiness, and the purpose-built probe covers the write question. Not
a lying-tool finding, and esme explicitly declined to record one.

THE HOP IS MIRROR -> GITHUB ON WRITE, not forge -> mirror. Fetch and ls-remote
rc=0 with the trunk advancing during the test; the mirror ACCEPTS the push, then
its relay fails upstream and refuses the transaction atomically: "[relay]
Pre-push fetch succeeded" then "Permission to 8007342/tillandsias.git denied to
8007342" / 403. The latest/stable/unstable "would clobber existing tag" lines
are the reconcile fallback after the real failure, not a second fault.

CREDENTIAL IS PRESENT-AND-REFUSED, established four ways without reading the
secret: relay-refs.sh's absent-credential branch never fired (so the Vault read
of `secret/github/token` succeeded and the Agent sink is healthy — NOT the
414/424 "do NOT run GitHub Login" case); the relay's own pre-push fetch used the
same credential successfully; GitHub named the account before refusing; and
probe-upstream-auth.sh's classifier chose `permission` while its `sso` and
`unauthenticated` arms did not match, positively ruling out an SSO gap and an
auth failure.

DO NOT INFER A SCOPE PROBLEM FROM THE WORDING. "Denied to 8007342" on 8007342's
own repo reads like a fine-grained-PAT scope fault and is not reliably that: on
2026-08-15 the identical string was an EXPIRED PAT (809-w2xy). Expired,
wrong-scope and removed-collaborator are indistinguishable from inside a forge.
esme nearly filed the scope reading and stopped itself; recorded because the
next reader will have the same instinct.

**Smallest operator action, superseding the one above:** on esmeraldinha, renew
the GitHub PAT at github.com/settings/tokens (check EXPIRY FIRST), confirm it
carries repo write to 8007342/tillandsias, re-seed Vault `secret/github/token`
on that host, and verify `git ls-remote <origin> 'refs/tillandsias/upstream-auth/*'`
shows `authorized/<epoch>`. Do NOT import host credentials. Do NOT rebuild the
git image for this.
