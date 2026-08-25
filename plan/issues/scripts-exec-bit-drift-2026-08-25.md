# `scripts/check-credential-channel.sh` landed non-executable — caught by the 731-d89b gate

- Date: 2026-08-25
- Host: linux_immutable, branch `linux-next`
- Class: `optimization` (executable guard made non-executable)
- Status: fixed this cycle

## Observation

`scripts/check-credential-channel.sh` was tracked mode `100644` at HEAD. Two
consumers invoke it by path and therefore could not run it:

- `skills/meta-orchestration/SKILL.md` (Credential Channel Guard step) — observed
  live this cycle as `Permission non accordée`; the verdict was recoverable only
  because the agent retried with an explicit `bash` prefix.
- `openspec/litmus-tests/litmus-credential-channel-check-shape.yaml:32`, whose
  first step asserts `test -x scripts/check-credential-channel.sh`.

A guard the harness cannot execute is not a guard.

## The recurrence guard already exists — and it works

`./build.sh --check` step 731-d89b ("Checking scripts invoked by path are
executable") refuses the push and names the fix:

    REFUSED: scripts/check-credential-channel.sh is invoked by path but tracked
             as mode 100644 — on a POSIX host that invocation is a permission
             error, not a verdict.
    Fix: git update-index --chmod=+x scripts/check-credential-channel.sh
    violation:script-not-executable:1

Worth recording, because it is the trap this cycle fell into first: a plain
`chmod +x` fixes the WORKTREE and leaves the INDEX at 100644, so the gate keeps
refusing and the mode never reaches the remote. `git update-index --chmod=+x` —
exactly what the verdict prints — is the fix that lands.

The remaining 32 non-executable `scripts/*.sh` are sourced libraries
(`common.sh`, `litmus-stdlib.sh`, `timing-log.sh`, the `help-*.sh` set) or are
invoked with an explicit interpreter; 731-d89b passes on them by design. No new
gate is proposed — the existing one covers the class.

## Fix applied

    git update-index --chmod=+x scripts/check-credential-channel.sh

Mode change only, no content change. `test -x` passes; 731-d89b re-run clean.
