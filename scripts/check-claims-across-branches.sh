#!/usr/bin/env bash
# @trace spec:meta-orchestration
# @trace order:1034-whsp
#
# check-claims-across-branches.sh — is this packet claimed on a SIBLING branch?
#
# WHY THIS EXISTS, MEASURED ON tlatoanis-macbook-air 2026-09-05.
#
# 1034-whsp was filed as a LATENCY bug: "a claim is invisible for as long as its
# push takes". yoga measured the push and reframed it once — the retry loop costs
# 18-56ms, the pre-push hook costs ~6.5s, and the actionable rule became "the
# claim commit must contain the claim fragment and nothing else".
#
# THE SECOND-HOST MEASUREMENT REFRAMES IT AGAIN, AND THE PUSH IS NOT THE PROBLEM.
# A claim from a platform host does not become visible to a trunk host when the
# push lands. It becomes visible when the COORDINATOR RELAYS the platform branch
# into linux-next, and that is a different clock entirely:
#
#   claim push, osx-next, claim-only diff ....... 12.0s total
#     (0.7s refused for the mandated linux-next merge, 0.5s merge, 10.8s push;
#      the plan-only lane DID accept it, scoped past the merge — 1056-5344 and
#      1060-7mmm already made the lane merge-aware, so the lane is not the gap)
#   osx-next -> linux-next relay gaps ........... 19m to 2h02m across the last 9
#   time since the last relay when this was written ... 6h28m
#   two of this host's own claims, still unseen ....... 1h55m and 2h11m
#
# So the invisibility window is not ten minutes (the filed incident) and not
# twelve seconds (the push). For a platform host it is the relay interval, and
# it is worst exactly when the trunk is busiest — the property the packet's
# title names, arriving through topology rather than through retries.
#
# MEASURED DIRECTLY, folding each branch's ledger with `--index`:
#   origin/linux-next fold ... 1034-whsp  ready        <- what a linux host selects on
#   this checkout ............ 1034-whsp  in_progress  <- I hold it
# 8 of this host's fragments were absent from linux-next at that moment.
#
# WHY (a), (b) AND (d) FROM THE PACKET CANNOT FIX IT. They all optimise the push:
# more retries, a fresher read before pushing, an always-mergeable claim push.
# The push already completes in seconds. Nothing done on the pushing host makes a
# fragment appear on a branch nobody has merged yet.
#
# WHY THIS IS (c), THE SMALLEST VERSION. `git ls-remote origin 'refs/tillandsias/*'`
# returns ZERO refs, so the out-of-band store the packet hoped the mirror already
# carried does not exist. Rather than build one, this reads what is ALREADY
# published: every platform branch is on origin, and a claim is a fragment file.
# Unioning the fragment listings across the sibling branches answers "is anyone
# else holding this" without any new channel, and without waiting for a relay.
#
# NOT A LOCK. It closes the window from a relay interval to one fetch; two hosts
# claiming inside the same fetch still collide, and the timestamp rule still
# arbitrates. It converts an hours-wide race into a seconds-wide one.
#
# Verdict grammar, one line on stdout:
#   ok:cross-branch-claims:<n> sibling branch(es) checked          exit 0
#   claimed-elsewhere:<packet>:<branch>:<host>                     exit 1
#   blocked:<reason>                                               exit 2
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "blocked:no-root"; exit 2; }

# ── --batch: FOLD ONCE PER RUN, NOT ONCE PER CANDIDATE (order 1034-whsp) ────
#
# The per-packet form below folds every sibling branch for every question asked.
# That is right for the CLAIM step, which asks about one packet — but criterion 2
# names the SELECTOR, which asks about every candidate in its frontier, and
# folding three branches per candidate would put the whole remedy's cost on the
# step that runs most often.
#
# The fold is the expensive part (git archive + tar + a ledger fold, ~1.0s for
# three branches); asking an ALREADY-FOLDED index about one more packet is
# cheap. So --batch folds each sibling once and then answers for every id given.
# That is macbookair's stated next action for this packet, in the form their
# per-packet check already established.
#
#   check-claims-across-branches.sh --batch <id> [<id>...]
#     claimed-elsewhere:<packet>:<branch>   (one line per hit, exit 1 if any)
#     ok:cross-branch-claims:<n> sibling branch(es) checked, <m> packet(s)
#     blocked:<reason>                      exit 2 — NEVER read as unclaimed
BATCH=0
if [ "${1:-}" = "--batch" ]; then
    BATCH=1
    shift
    [ $# -gt 0 ] || { echo "usage: check-claims-across-branches.sh --batch <id> [<id>...]" >&2; exit 2; }
    BATCH_IDS="$*"
    PACKET=""
    NO_FETCH=0
else
    PACKET="${1:-}"
    [ -n "$PACKET" ] || { echo "usage: check-claims-across-branches.sh <packet-id-or-order> [--no-fetch] | --batch <id>..." >&2; exit 2; }
    NO_FETCH=0
    [ "${2:-}" = "--no-fetch" ] && NO_FETCH=1
    BATCH_IDS=""
fi

# RESOLVE THE VALIDATOR THROUGH THE SHARED PROBE, AND REFUSE WITHOUT ONE.
# This is 1024-c3h3 in advance: that fixture asked a checker a question from a
# directory where its cwd-relative probe found nothing, the checker took its
# "not built" branch, and the SKIP read as a pass — including on a negative
# control, which then agreed for the wrong reason. Here the wrong reason would
# be worse: "no binary" would print "nobody else holds this packet" and hand a
# claimed packet to a second host. An unanswerable question must be BLOCKED, not
# answered optimistically.
# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
PLAN_BIN="$(resolve_plan_binary 2>/dev/null)" || PLAN_BIN=""
case "$PLAN_BIN" in ./*) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;; esac
if [ -z "$PLAN_BIN" ]; then
    echo "blocked:no-plan-binary — cannot fold a sibling branch's ledger, so this says NOTHING about who holds a packet or any packet; build with ./build.sh (never read this as unclaimed)" >&2
    echo "blocked:no-plan-binary"
    exit 2
fi

SIBLINGS="linux-next windows-next osx-next"

# ── ORDER 1104-w9np — SUBTRACT THE READER'S OWN AUTHORSHIP ──────────────────
#
# MEASURED on lenovinha 2026-09-06: their OWN in_progress claim, merged into
# osx-next and windows-next by routine integration, came back at them as "A
# sibling branch holds this packet in_progress ... It is NOT yours to
# implement." 1071-adhj then sat in_progress for a day — hidden from ready and
# from burndown — with all four criteria met and the work already relayed.
#
# THE ADVICE IS WRONG IN THE MOST EXPENSIVE DIRECTION: it tells a host to keep
# its hands off its own finished work, and it is authoritative on exactly this
# question, so the host repeats it to the coordinator as fact.
#
# IT INTENSIFIES AS COORDINATION IMPROVES. Every sibling merge the coordinator
# performs adds another branch reflecting a claim back at its author, so the
# condition is more reachable after a good relay pass than before it.
#
# WHO WROTE THE WINNING STATUS: the fold decides the STATUS (that is why the
# loop below asks the binary and not a grep — 635-i6vm), and this answers the
# separate question of ATTRIBUTION by taking the status entry for this packet
# with the greatest ts. Both are ts-LWW so they agree; where they might not, the
# comparison below FAILS TOWARD THE EXISTING VERDICT, never toward silence.
# THE FIXTURE SEAM, and what it does NOT cover. TILLANDSIAS_XBRANCH_CLAIM_HOST
# forces the attribution, because the arms drive sibling folds through a STUB
# plan binary against the REAL origin refs — a fixture cannot plant a fragment
# on origin/osx-next, and one that tried would be testing git rather than this
# decision. The seam makes the DECISION testable; the PARSER below is covered
# separately by an arm that runs it against a planted fragment file, so neither
# half rests on the other.
_claim_host_on_branch() { # _claim_host_on_branch <archived-tree> <packet-id-or-order>
    if [ -n "${TILLANDSIAS_XBRANCH_CLAIM_HOST:-}" ]; then
        printf '%s' "$TILLANDSIAS_XBRANCH_CLAIM_HOST"
        return 0
    fi
    local tree="$1" who="$2" f best_ts="" best_host=""
    for f in "$tree"/plan/index.d/*.yaml; do
        [ -e "$f" ] || continue
        # A status entry names the packet, the field, and its host. Read the
        # block that mentions this packet and carries `field: status`.
        awk -v want="$who" '
            /^[[:space:]]*-[[:space:]]*packet_id:/ { pid=$0; sub(/^[^:]*:[[:space:]]*/,"",pid); inblk=(index(pid,want)>0 || index(want,pid)>0); f=""; t=""; h="" }
            inblk && /^[[:space:]]*field:[[:space:]]*status[[:space:]]*$/ { f=1 }
            inblk && /^[[:space:]]*ts:/ { t=$0; sub(/^[^:]*:[[:space:]]*/,"",t); gsub(/"/,"",t) }
            inblk && /^[[:space:]]*host:/ { h=$0; sub(/^[^:]*:[[:space:]]*/,"",h); if (f && t != "" && h != "") print t "\t" h }
        ' "$f" 2>/dev/null
    done | sort -r | head -1 | cut -f2
}

# BOTH VOCABULARIES COUNT AS "ME", and 1012-hu7d is why: a claim written with
# --host yoga and a later fragment written without it (falling back to
# TILLANDSIAS_HOST_KIND, i.e. the platform bucket `linux`) are the SAME host
# wearing two labels, and no query keyed on one returns the other. A reader that
# only knew one of its names would still be told to leave its own work alone.
_is_me() { # _is_me <host-label>
    local h="$1"
    [ -n "$h" ] || return 1
    local node; node="$(hostname -s 2>/dev/null || echo)"
    [ "$h" = "$node" ] && return 0
    [ "$h" = "${TILLANDSIAS_WORKSTATION:-}" ] && return 0
    [ "$h" = "${TILLANDSIAS_HOST_KIND:-}" ] && return 0
    [ "$h" = "$(uname -s | tr 'A-Z' 'a-z')" ] && return 0
    return 1
}

CURRENT="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || CURRENT=""

if [ "$NO_FETCH" = 0 ]; then
    # One fetch, all siblings. This is the whole cost of the remedy.
    git fetch -q origin $SIBLINGS 2>/dev/null || {
        # A fetch failure must not read as "nobody else holds it" — that is the
        # false-negative this check exists to prevent, and it would be silent.
        echo "blocked:fetch-failed — cannot see sibling branches, so this says NOTHING about who holds ${PACKET:-these packets}" >&2
        echo "blocked:fetch-failed"
        exit 2
    }
fi

if [ "$BATCH" = 1 ]; then
    checked=0
    hits=0
    for b in $SIBLINGS; do
        git rev-parse --verify -q "origin/$b" >/dev/null 2>&1 || continue
        [ "$b" = "$CURRENT" ] && continue
        checked=$((checked + 1))
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/xbranch.XXXXXX")"
        if git archive "origin/$b" plan/index.yaml plan/index.d 2>/dev/null | tar -x -C "$tmp" 2>/dev/null; then
            # TWO STAGES, because `status` answers ONE id per invocation at
            # ~650ms and each invocation re-folds the ledger. A frontier of 200
            # candidates across two siblings would be 260s — unusable at the
            # step that runs most often, which is the whole reason this mode
            # exists.
            #
            # Stage 1 is ONE call: `ready any` lists everything READY on that
            # branch (183 rows, ~530ms). A candidate PRESENT there is not
            # claimed there, and that clears almost every id for free.
            # Stage 2 asks `status` only for the few that are absent, because
            # absent-from-ready is not the same as in_progress — it also covers
            # done, blocked and obsoleted, and reporting those as
            # claimed-elsewhere would be a false accusation that sends a host
            # away from work nobody holds.
            ready_here="$("$PLAN_BIN" --index "$tmp/plan/index.yaml" ready any 2>/dev/null | awk '{print $1}')"
            if [ -z "$ready_here" ]; then
                # The fold produced no ready set at all: treat as unusable
                # rather than as "everything is claimed".
                echo "blocked:empty-fold:$b" >&2
                rm -rf "$tmp"
                continue
            fi
            for id in $BATCH_IDS; do
                case "
$ready_here
" in
                    *"
$id
"*) continue ;;
                esac
                st="$("$PLAN_BIN" --index "$tmp/plan/index.yaml" status "$id" 2>/dev/null | awk '{print $2}')"
                if [ "$st" = in_progress ]; then
                    echo "claimed-elsewhere:$id:$b"
                    hits=$((hits + 1))
                fi
            done
        fi
        rm -rf "$tmp"
    done
    if [ "$checked" -eq 0 ]; then
        # No sibling could be folded. Saying "none claimed" here is the false
        # negative this file exists to prevent.
        echo "blocked:no-siblings-folded" >&2
        echo "blocked:no-siblings-folded"
        exit 2
    fi
    n_ids="$(printf '%s\n' $BATCH_IDS | grep -c . || true)"
    echo "ok:cross-branch-claims:$checked sibling branch(es) checked, ${n_ids} packet(s)"
    [ "$hits" -gt 0 ] && exit 1
    exit 0
fi

checked=0
found=""
# ORDER 1091 (filed with this change): does the packet EXIST on any branch?
# Without this the verdict cannot distinguish "nobody holds it" from "there is
# no such packet", and both print ok. MEASURED: this tool answered
# `ok:cross-branch-claims:2 sibling branch(es) checked` for
# `definitely-not-a-real-packet-xyz`, and for 1090-8nh4 in the window before its
# author had pushed it — so a host acting on that ok would claim a phantom.
# It is the defect this tool was built to catch, in the tool itself: a green
# answering a narrower question than the sentence attached to it.
seen_anywhere=0
mine=""
for b in $SIBLINGS; do
    git rev-parse --verify -q "origin/$b" >/dev/null 2>&1 || continue
    [ "$b" = "$CURRENT" ] && continue
    checked=$((checked + 1))
    # Fold that branch's ledger and ask it directly, rather than grepping
    # fragments: status is LWW and a later fragment can release a claim, so the
    # raw presence of a claim fragment is NOT the same question (635-i6vm).
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/xbranch.XXXXXX")"
    if git archive "origin/$b" plan/index.yaml plan/index.d 2>/dev/null | tar -x -C "$tmp" 2>/dev/null; then
        st="$("$PLAN_BIN" --index "$tmp/plan/index.yaml" status "$PACKET" 2>/dev/null | awk '{print $2}')"
        [ -n "$st" ] && seen_anywhere=1
        if [ "$st" = in_progress ]; then
            # 1104-w9np: whose claim is it? A holder that is THIS host is the
            # reader's own claim reflected back by a sibling that merged their
            # branch — not a sibling's claim.
            _h="$(_claim_host_on_branch "$tmp" "$PACKET")"
            if _is_me "$_h"; then
                mine="${mine:+$mine }$b"
            else
                # Unattributable is NOT "mine". An empty or unrecognised host
                # falls here deliberately: the only safe direction for an
                # ambiguous answer is the existing verdict, because treating a
                # sibling's claim as your own is the failure this whole file
                # exists to prevent.
                found="${found:+$found }$b"
            fi
        fi
    fi
    rm -rf "$tmp"
done

if [ -z "$found" ] && [ -n "$mine" ]; then
    # THE VERDICT THE ROW ASKS FOR, and it is an ok rather than a refusal: every
    # branch carrying this claim carries it under THIS host's own label, so the
    # work is the reader's to resume.
    for b in $mine; do
        echo "own-claim-reflected:$PACKET:$b"
    done
    echo "  Every sibling branch holding this packet in_progress records THIS HOST as the" >&2
    echo "  claimant — your own claim, merged back by routine integration (1104-w9np)." >&2
    echo "  It IS yours: resume it, or release it with set-field status ready if you are" >&2
    echo "  not going to finish it. Measured cost of the old answer: a day of finished work" >&2
    echo "  left stranded because the tool said 'NOT yours to implement' about its author's" >&2
    echo "  own claim." >&2
    echo "ok:cross-branch-claims:$checked sibling branch(es) checked; own claim reflected by $(printf '%s' "$mine" | wc -w | tr -d ' ')"
    exit 0
fi

if [ -n "$found" ]; then
    for b in $found; do
        echo "claimed-elsewhere:$PACKET:$b"
    done
    echo "  A sibling branch holds this packet in_progress and your fold has not seen it yet." >&2
    echo "  It is NOT yours to implement. Arbitration is by claim TIMESTAMP, not push order:" >&2
    echo "  if yours is earlier you continue; if theirs is earlier you release and reroute." >&2
    exit 1
fi
# The local fold counts as existence too: a packet this host just filed is real
# even before it reaches a sibling.
if [ "$seen_anywhere" -eq 0 ]; then
    "$PLAN_BIN" status "$PACKET" >/dev/null 2>&1 && seen_anywhere=1
fi
if [ "$seen_anywhere" -eq 0 ]; then
    echo "  No branch and no local fold knows this packet. That is NOT the same" >&2
    echo "  as unclaimed: an ok here would send you to claim something that does" >&2
    echo "  not exist, or that its author has not pushed yet." >&2
    echo "unknown-packet:$PACKET:$checked sibling branch(es) checked"
    exit 2
fi
echo "ok:cross-branch-claims:$checked sibling branch(es) checked"
