# BLOCKER: the gh keyring token went invalid MID-CYCLE, after the guard had passed

- Date: 2026-08-25
- Host: calmecacpilli, `linux_immutable`, branch `linux-next`
- Class: `blocked`
- Owner: operator (needs an interactive re-auth this agent cannot perform)

## Observation

The Start-Of-Cycle Credential Channel Guard passed:

    scripts/check-credential-channel.sh  ->  ok:gh-keyring-push-verified

Two pushes then succeeded on that credential (`7cf78cde0`, `6810d17e4`). Later
in the SAME cycle, the push of the 889-twhe commit failed:

    remote: Invalid username or token. Password authentication is not supported
    fatal: Échec d'authentification pour 'https://github.com/8007342/tillandsias.git/'

Re-running the guard now:

    scripts/check-credential-channel.sh  ->  missing:no-credential-channel  (rc=1)
    gh auth status                       ->  "The token in keyring is invalid."

So the token was valid at Start-Of-Cycle and invalid ~50 minutes later, with no
action by this cycle in between. Expiry, revocation, or a keyring re-lock.

## Smallest next action

Operator, on this host:

    gh auth refresh -h github.com

Then re-run `scripts/check-credential-channel.sh` (expect
`ok:gh-keyring-push-verified`) and push the pending local commit.

## State left behind

One local commit is COMMITTED AND UNPUSHED on `linux-next`: the 889-twhe
implementation plus this host's capability row. `./build.sh --check` passed
green against it (142s) before the push was attempted, so it is gate-clean and
needs only a working credential.

No `MO-FULL:` marker was emitted for this cycle, deliberately: the marker's
first invariant is `LOCAL_SHA == REMOTE_SHA`, and a marker may never follow an
unpushed local commit. The missing marker IS the loud failure, as designed.

## The residual worth reducing

The guard is a START-OF-CYCLE check, and this credential died mid-cycle. A
guard that samples once cannot see an expiry that happens after it runs, and
the failure then surfaces at the most expensive possible moment — after the
work, after a 142s gate, at the push. Candidate reduction, NOT enabled here
(raising the bar is Tlatoani-gated): re-probe the channel immediately before
the first push of a cycle, which is cheap and would move the discovery from
"after everything" to "before the gate". Filed as a candidate for whoever owns
the credential lane.
