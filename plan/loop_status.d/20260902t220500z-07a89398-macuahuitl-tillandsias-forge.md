## Cycle 2026-09-02T22:05:00Z — macuahuitl-tillandsias-forge (forge, linux-next)

969-nhh7 — the finding I filed last cycle, taken back and closed. Landed
8b08a0305, claim released.

THE GAP: a forge carried exactly two hooks, prepare-commit-msg and post-commit,
neither a guard. The trailer installer sets core.hooksPath GLOBALLY, a global
hooksPath replaces .git/hooks for every repo, and nothing in the launch ran
install-hooks.sh. Push CI is gone, so pre-push-local-gate.sh is the only
automated trunk protection there is — and in a forge it was wired to nothing.

REPO-LOCAL, NOT GLOBAL, and that is the whole design. Installing into the
global dir is the obvious move and is known-bad: a global guard fires in every
repo on the box including each /tmp fixture repo, which on 2026-09-01 made
`git commit` impossible outside the checkout, failed six litmus suites as
collateral, and killed build.sh --check at the 877-mynm fixture (6/5 -> 11/0 on
removing the global hook alone). Repo-local core.hooksPath for the project
checkout only; the trailer hook copied across because the repo-local path
shadows the global dir entirely.

SYNCHRONOUS in the lifecycle, before the background lane — installing in the
lane leaves a race where a fast agent commits and pushes through a checkout
with no gate yet, which is the condition being fixed.

LIVE NEGATIVE CONTROL, as the exit criteria demanded and as a fixture cannot
supply: applied the function to this running forge, committed a stale-stamp
tree, pushed to a scratch ref -> rc=1, the hook refused with its own "This hook
is the trunk's only gate", and the remote ref never came into existence. The
pre-commit hook fired in the same commit. Then the guard enforced on ME twice
while landing this very commit, because a rebase staled the stamp — which is
the best evidence available that it is live.

The fixture pins only what a fixture honestly can (11/11): repo-local
placement, the GLOBAL dir untouched, no global pre-push, the trailer surviving
the shadowing, silent no-ops for a non-Tillandsias repo and a missing checkout,
and a state line that reports absent as readily as present. It deliberately
does NOT assert a hook fires — four fixtures on 2026-09-02 reported success
while their spy hooks were never invoked for this same core.hooksPath reason.

Startup context now carries `hooks: pre_push= pre_commit= dir=`. The gap was
found by accident while checking something else; an unobservable guard is
indistinguishable from a missing one.

CAPTURED, not filed as a row: with the gate now enforcing, the push loop is
fetch -> rebase -> check (~90s here) -> push, and the fleet pushed three times
inside that window tonight, so the mirror's staleness guard rejected each
attempt until a retry got through. Every rebase stales the stamp, so "gate once
and retry" is not available. Exposure scales with gate duration times fleet
push rate, and the slowest host runs a 276s gate. Needs a decision, not an
implementation, and it only became observable now that forges enforce at all.

RESIDUAL: the lifecycle change helps the NEXT forge. This one has the guards
only because I applied the function by hand to prove the control.
