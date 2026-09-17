#!/usr/bin/env bash
# @trace order:1196-5hva, spec:observability-metrics
#
# test-fleet-heartbeat-sees-a-ledger-filed-blocker.sh — the first fixture this
# classifier has ever had.
#
# WHAT IT PINS. fleet-heartbeat.sh sorts hosts into healthy/wedged/blocked/dead,
# and the names are instructions: WEDGED means "adjudicate its worktree", BLOCKED
# means "read the record it filed". Getting that backwards costs hours in the
# direction the script's own header documents, and cost them again in reverse
# during 1193-yw6u — both macOS hosts read WEDGED while a ledger packet named a
# trunk-wide red another host had already diagnosed, so the advice pointed at
# local dirt that was not there.
#
# TWO DEFECTS, both covered here:
#   1. the blocked source was a `- Status: blocked` line in plan/issues markdown,
#      written TWICE in the project's entire history (macneo's `git log -S`,
#      2026-09-15) and zero times today — not broken, UNREACHABLE, because hosts
#      record blockers as ledger packets now.
#   2. the WEDGED branch was evaluated BEFORE the blocked branch and returned
#      first, so a host that keeps COMMITTING never reached the blocker lookup at
#      all — and filing what blocked you is a commit. macbookair filed three
#      packets during the window and would still have read WEDGED with a perfect
#      blocker source, because nothing asked.
#
# Hermetic: every arm builds a throwaway repo with its own plan/ tree, its own
# git history, and a STUB plan binary injected through TILLANDSIAS_PLAN_BIN, so
# no arm reads this checkout's ledger or this fleet's real state.
#
# THE ARMS THAT MATTER ARE THE NEGATIVE CONTROLS (3, 4, 6, 7b, 8). A detector that
# resurrects stale blocks, or invents them when it cannot fold the ledger, says
# "blocked" about everything and is worse than the silence it replaced.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/fleet-heartbeat.sh"
[ -f "$SCRIPT" ] || { echo "skip:fleet-heartbeat:script absent"; exit 3; }

W="$(mktemp -d "${TMPDIR:-/tmp}/fleet-heartbeat.XXXXXX")" || exit 3
trap 'rm -rf "$W"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OLD_ISO="$(date -u -d '40 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -v-40H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
[ -n "$OLD_ISO" ] || { echo "skip:fleet-heartbeat:cannot compute a past timestamp portably"; exit 3; }

# scaffold <name> <blocked-orders-the-stub-reports>
# Builds a repo whose host `probe` attested LONG ago and committed JUST NOW —
# the alive-and-failing shape that lands in the wedged branch.
scaffold() {
    local d="$W/$1" blocked="${2:-}"
    mkdir -p "$d/scripts" "$d/plan/index.d" "$d/plan/issues" "$d/plan/mo-full-attestations.d"
    cp "$SCRIPT" "$d/scripts/fleet-heartbeat.sh"
    cp "$ROOT/scripts/plan-binary-probe.sh" "$d/scripts/plan-binary-probe.sh"
    # An attestation old enough to be past the silence window.
    printf '## %s\nattested\n' "$OLD_ISO" > "$d/plan/mo-full-attestations.d/probe.md"
    # A stub plan binary: the roster, the capability matrix, and the folded blocked set.
    cat > "$d/plan-stub" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"capability-matrix --hosts"*) printf 'probe\tcpu\tnone\n' ;;
  *"capability-matrix"*)         printf 'host:probe\tlocus:bare-metal\tkind:linux\tderived_tier:cpu\n  schedulable: cpu/container/ollama\n' ;;
  *"query --status blocked"*)    printf '%s\n' $( [ -n "$blocked" ] && printf "'%s'" "$blocked" || printf "''" ) ;;
esac
exit 0
STUB
    chmod +x "$d/plan-stub"
    # THE IDENTITY IS PINNED IN THE ENVIRONMENT, NOT ONLY IN git config.
    # last_commit_epoch() matches `git log --author=probe`, so the whole WEDGED
    # signal depends on this commit being authored by `probe`. `git config
    # user.name probe` is NOT enough: an ambient GIT_AUTHOR_NAME/GIT_AUTHOR_EMAIL
    # overrides repo config, and a forge (or any agent session) exports both —
    # measured 2026-09-16, the scaffold commit landed as
    # "Tlatoani <bulloncito@gmail.com>", `git log --author=probe` was empty, and
    # arms 1/3/4/8 read SILENT. Pin author AND committer in the env so the
    # fixture is hermetic against the session it runs in.
    ( cd "$d" && git init -q 2>/dev/null \
        && GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@probe \
           GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@probe \
           git -c commit.gpgsign=false commit -q --allow-empty \
               -m "recent activity by probe" ) >/dev/null 2>&1
    printf '%s' "$d"
}

# A ledger packet carrying a blocked_by token. Both kinds are accepted
# (operator, 2026-09-15, "use both: CRDT style"): a colon-bearing token is a
# CAPABILITY and matches whatever host answers to it; a bare token is a HOST
# identity. Union, so two writers need not agree on which they use.
add_ledger_block() { # add_ledger_block <dir> <packet_id> <order> <blocked_by-token>
    cat > "$1/plan/index.d/20260915t000000z-block-$3.yaml" <<FRAG
packets:
  - packet_id: $2
    order: $3
    status: blocked
    blocked_by: $4
    ts: "2026-09-15T00:00:00Z"
FRAG
}

run_hb() { # run_hb <dir> [use-stub]
    local d="$1" stub="${2:-yes}"
    if [ "$stub" = "yes" ]; then
        ( cd "$d" && TILLANDSIAS_PLAN_BIN="$d/plan-stub" bash scripts/fleet-heartbeat.sh 2>/dev/null )
    else
        ( cd "$d" && env -u TILLANDSIAS_PLAN_BIN PATH=/usr/bin:/bin bash scripts/fleet-heartbeat.sh 2>/dev/null )
    fi
}

echo "arm 1 — a LEDGER-filed blocker, on a host that is alive and committing, reads BLOCKED"
D="$(scaffold ledger "42-abcd")"
add_ledger_block "$D" "some-packet" "42-abcd" "kind:linux"
OUT="$(run_hb "$D")"
if printf '%s' "$OUT" | grep -q 'BLOCKED, alive and failing'; then
    ok "named BLOCKED and still shown as alive and failing"
elif printf '%s' "$OUT" | grep -q 'WEDGED'; then
    bad "still WEDGED — the wedged branch is answering before the blocker is consulted (1196-5hva defect 2)"
else
    bad "unexpected classification: $(printf '%s' "$OUT" | grep probe)"
fi
if printf '%s' "$OUT" | grep -q '42-abcd'; then
    ok "the line names the packet, so the reader gets the blocker instead of a hunt"
else
    bad "the blocker is not named in the host's line"
fi

echo "arm 2 — the verdict line counts it in the blocked bucket, not wedged"
if printf '%s' "$OUT" | grep -qE '^ok:fleet-heartbeat:[0-9]+/0/1/'; then
    ok "ok:fleet-heartbeat:*/0/1/* — zero wedged, one blocked"
else
    bad "bucket counts wrong: $(printf '%s' "$OUT" | grep '^ok:fleet-heartbeat:')"
fi

echo "arm 3 — NEGATIVE CONTROL: a block the fold has since lifted must NOT resurrect"
# The fragment still says blocked forever (fragments are immutable); the FOLD is
# what knows it was unblocked. Reading the fragment alone gives a detector that
# can only ever say 'blocked'.
D="$(scaffold stale "")"          # stub reports an EMPTY blocked set
add_ledger_block "$D" "some-packet" "42-abcd" "kind:linux"
OUT3="$(run_hb "$D")"
if printf '%s' "$OUT3" | grep -q 'WEDGED'; then
    ok "not blocked — the folded set is the authority, the fragment only attributes"
else
    bad "a lifted block came back from an immutable fragment: $(printf '%s' "$OUT3" | grep probe)"
fi

echo "arm 4 — NEGATIVE CONTROL: a host with NO blocker anywhere still reads WEDGED"
D="$(scaffold nothing "")"
OUT4="$(run_hb "$D")"
if printf '%s' "$OUT4" | grep -q 'WEDGED, alive and failing'; then
    ok "silence is still an unexplained wedge — the fix did not turn every host blocked"
else
    bad "a host with no blocker was reclassified: $(printf '%s' "$OUT4" | grep probe)"
fi

echo "arm 5 — the plan/issues markdown source still works (864-w7rc is not removed)"
D="$(scaffold markdown "")"
printf -- '- Status: blocked\n' > "$D/plan/issues/probe-wedge.md"
OUT5="$(run_hb "$D")"
if printf '%s' "$OUT5" | grep -q 'BLOCKED'; then
    ok "the markdown record is still honoured beside the ledger"
else
    bad "the original blocked source regressed: $(printf '%s' "$OUT5" | grep probe)"
fi

echo "arm 6 — NEGATIVE CONTROL: with NO plan binary, the ledger source is OFF"
# A host that cannot fold the ledger must not invent blockers from fragments it
# cannot verify. It falls back to exactly the pre-1196-5hva behaviour.
D="$(scaffold nobinary "")"
add_ledger_block "$D" "some-packet" "42-abcd" "kind:linux"
OUT6="$(run_hb "$D" no)"
if printf '%s' "$OUT6" | grep -q 'BLOCKED'; then
    bad "invented a blocker with no way to fold the ledger — unverifiable fragments must not be believed"
else
    ok "ledger source disabled without a plan binary; markdown source stands alone"
fi

echo "arm 7 — a HOST NAME in blocked_by also matches (operator: use both, CRDT style)"
# Both token kinds are accepted additively. A capability token survives the
# roster turning over; a host token is the right thing for a here-and-now block
# on a named machine. Two writers can name the same block differently and
# neither has to know about the other.
D="$(scaffold hostname_tok "42-abcd")"
add_ledger_block "$D" "some-packet" "42-abcd" "probe"
OUT7="$(run_hb "$D")"
if printf '%s' "$OUT7" | grep -q 'BLOCKED'; then
    ok "a bare host token matched, beside the capability tokens"
else
    bad "a host-identity token did not match: $(printf '%s' "$OUT7" | grep probe)"
fi

echo "arm 7b — NEGATIVE CONTROL: ANOTHER host's name still matches nothing here"
# The union widens which tokens are understood, never which HOST they point at.
D="$(scaffold otherhost "42-abcd")"
add_ledger_block "$D" "some-packet" "42-abcd" "some-other-box"
OUT7B="$(run_hb "$D")"
if printf '%s' "$OUT7B" | grep -q 'BLOCKED'; then
    bad "another machine's name explained this host's silence"
else
    ok "a different host's token does not match this host"
fi

echo "arm 8 — a capability NO host answers yet matches nothing, and is not an error"
# CRDT-shaped: a fact may be written before the thing it describes exists. A
# blocker naming a capability nobody has today must simply not match, so the
# ledger can carry it until some future host answers to it.
D="$(scaffold future "42-abcd")"
add_ledger_block "$D" "some-packet" "42-abcd" "schedulable:qpu"
OUT8="$(run_hb "$D")"
if printf '%s' "$OUT8" | grep -q 'BLOCKED'; then
    bad "an unmatched capability was attributed to a host that does not answer it"
elif printf '%s' "$OUT8" | grep -q 'WEDGED'; then
    ok "unmatched capability matches nothing and classification continues normally"
else
    bad "unexpected: $(printf '%s' "$OUT8" | grep probe)"
fi

echo "arm 9 — a capability token OTHER than kind: also matches (vocabulary is not hardcoded)"
D="$(scaffold sched "42-abcd")"
add_ledger_block "$D" "some-packet" "42-abcd" "schedulable:cpu"
OUT9="$(run_hb "$D")"
if printf '%s' "$OUT9" | grep -q 'BLOCKED'; then
    ok "schedulable: matched — the matcher reads whatever vocabulary the matrix publishes"
else
    bad "only kind: matched, so the vocabulary is effectively hardcoded: $(printf '%s' "$OUT9" | grep probe)"
fi

echo
echo "fleet-heartbeat ledger blocker: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    echo "violation:fleet-heartbeat-ledger-blocker:$fail"
    exit 1
fi
echo "ok:fleet-heartbeat-ledger-blocker:$pass"
exit 0
