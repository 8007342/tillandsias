## Cycle 2026-08-17T05:24Z (linux-immutable yoga — cycle 11, hourly fleet loop)

789-nc2s COMPLETED (b248882cd) and the deferred forge lane RAN, confirming
783-6rik for the third time.

789-nc2s. Both criteria met. Criterion 1 turned out to need no fleet decision
after all: with the leaked /mnt/c FORGE_SPEC_INDEX_DIR removed last cycle,
every remaining value in the tracked config (loopback endpoints, a model name)
is host-independent, so untracking the file — which I had deferred as a fleet
call — is unnecessary. Criterion 2 is scripts/check-tracked-config-host-paths.sh:
refuses a tracked agent config whose ENV block hard-codes a one-machine path;
selftest 4/4 with negative controls for /mnt/c and /Users/, plus the exclusion
that keeps prose free to quote them (our own cheatsheets and packets cite
/mnt/c as evidence; a guard that flagged documentation for describing the
defect would be its own defect).

The guard's FIRST RUN corrected it twice, and both corrections are the
interesting part. (a) Writing the Windows shape as [A-Za-z]:[\\/] matches
every http:// URL — it now requires a single drive letter at a boundary,
because a guard that cries wolf on every endpoint gets switched off within a
day. (b) Scanning the whole file is too blunt: only the ENV block refuses,
since a leaked env value changes behaviour everywhere, while a host-specific
path inside a permissions allowlist is inert elsewhere. That distinction
immediately earned itself — the live scan found three Git-Bash paths
(/c/Users/bullo/...) in the permissions list that I had NOT seen. They are
surfaced as a note rather than deleted: removing another host's permission
entries is not a decision this host should make silently. Left for windows or
the operator.

I also introduced a ghost trace in that same commit (spec:multi-host-development
does not exist) and caught it on the pre-commit notice — retargeted to
spec:forge-environment-discoverability before pushing. Filing packets about
ghost traces all night and then adding one is exactly the shape worth naming
out loud.

FORGE LANE (third run, full-meta stamp recorded). Re-checked the preconditions
first: no new release (daily still resolves v0.4.260815.1, installed binary
agrees) and the versioned git image still carries no probe-upstream-auth. The
lane returned blocked:upstream-auth-unpublished and refused before any
committable work — the same verdict as the 20:22Z and 00:24Z lanes, now across
an intervening local image rebuild that the tray overwrote. 783-6rik's
mechanism is settled; recorded as a third data point rather than re-diagnosed.
The remaining action is a release, which is the operator's to cut.

CA migration held: cycle-preflight's clamp reported ok:ca-material:already-clamped
at start, so last cycle's 791-swxt fix is stable across a cycle boundary.

Metrics (verbatim): experts: calls=2033 answered=2023 unsupported=2 degraded=7
errors=1 answer_rate=99% | expert_accuracy: pass=22 total=22 rate=100% |
mcp: servers=3 per_server=cli=1995;forge-plan=38;project-info=40 health=ok |
flow: cycles=10 avg_completed_per_cycle=1.2 avg_commits_per_cycle=3.6
overhead_ratio=3.00 | timing: steps=262 build_check_ms_avg=15906
litmus_ms_avg=8799 | plan: packets=991 ready=344 | experts_substitution:
unknown. degraded/errors remain the test-induced no_such_tool probes explained
in cycle 9. Advisories: stranded=0, cheatsheet tree in sync.
