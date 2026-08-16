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
