#!/usr/bin/env bash
# freshness: auditor=linux-macuahuitl-opus5-20260820T0032Z date=2026-08-20 verdict=updated scope=831-ezea — the 2026-08-16 audit called this script SOUND and cited "--check proves idempotency by double-run diff" as the evidence. That reasoning was the defect, not the proof: idempotency is the wrong property. An archiver that deterministically archives rows it must not touch is perfectly idempotent, and this one was — it carried two READY rows (424, 437) into the archive while --check printed green, and it ORPHANED 38 live fragment events on its first real run. --check now asserts what actually matters: the ready set is byte-identical across a run, and the sweep creates no new orphaned events. Both are mutation-controlled. First real archive since 2026-07-05: 550 packets, index 60,241 -> 26,344 lines.
#
# THE AUDIT LESSON, kept because it is not about this script: a freshness audit
# that re-reads a tool's self-check and repeats its verdict inherits whatever
# that check was wrong about. "Sound" here meant "its --check passes", and the
# --check was measuring the wrong invariant. Ask what property the check
# ESTABLISHES before treating its green as evidence of anything.
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$(dirname "$DIR")"

# 777-amku toolbox-first pattern: this script has a HARD ruby dependency with
# no yq fallback (it runs .rb programs, not just YAML parsing). Ensure the
# toolbox, then prefer host ruby and fall back to the toolbox's — zero
# behavior change on hosts that carry ruby natively.
source "$DIR/ensure_toolbox.sh"
# 704-zcgi. The .rb now asks the FOLD which packets are terminal instead of
# grepping the base index, so this script has a hard tillandsias-plan
# dependency too — resolved by execution, through the one shared probe.
source "$DIR/plan-binary-probe.sh"
_ruby() {
    if command -v ruby >/dev/null 2>&1; then
        ruby "$@"
    else
        toolbox run --container tillandsias-builder ruby "$@"
    fi
}

cd "$REPO_ROOT"

# CLEAN UP ON EVERY EXIT, INCLUDING THE ONES NOBODY ANTICIPATED.
#
# This used to repeat `rm -rf plan_tmp ...` by hand at each early return —
# seven sites, and correct at all seven. It still leaked, because a hand-placed
# cleanup only covers exits you thought of: on 2026-08-23 the WSL gate lane
# crashed inside Ruby (empty LANG, US-ASCII default, 2,517 em-dashes in the
# ledger) and died without reaching any of them, leaving a full copy of plan/
# in the worktree. Every boundary-guarded cycle after that starts dirty, and a
# dirty start is precisely what stops an unattended host.
#
# A trap covers the crash, the SIGINT, and the exit path added next year by
# someone who never reads this comment. The manual sites below are left in
# place deliberately: they free the copy EARLY on long paths, and running the
# cleanup twice is harmless.
_archiver_cleanup() {
    rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb plan_tmp_*.txt
}

if [ "$1" == "--check" ]; then
    echo "Running in check mode..."
    trap _archiver_cleanup EXIT INT TERM
    rm -rf plan_tmp plan_tmp_bak
    cp -a plan/ plan_tmp/
    
    sed 's|plan/|plan_tmp/|g' scripts/archive-plan-packets.rb > scripts/archive-plan-packets-check.rb

    # THE ACCEPTANCE ASSERTION (831-ezea). Everything below the idempotency
    # diff was already here and it proved the WRONG PROPERTY. An archiver that
    # deterministically archives rows it must not touch is perfectly
    # idempotent: on 2026-08-19 this check printed "script is idempotent"
    # while the tool silently carried two READY rows — 424 and 437 — into the
    # archive, where they answer `no packet matches`. The script's own
    # freshness header then cited --check as evidence the tool was sound.
    #
    # Archiving moves TERMINAL rows. A ready row is by definition not terminal,
    # so the ready set is the invariant: it must be byte-identical across the
    # run. This is the assertion, and it fails loud.
    # 704-zcgi / 721-nyev: resolve by EXECUTION through the shared probe, never
    # by testing an executable bit at a hardcoded target/ path. The first draft
    # of this block did exactly that and the build gate caught it, which is the
    # gate working as designed — three scripts had already written that same
    # wrong probe independently.
    if ! PLAN_BIN="$(resolve_plan_binary)"; then
        echo "Check FAILED: no runnable tillandsias-plan, so the ready-set invariant"
        echo "  cannot be evaluated. Refusing to fall back to the idempotency-only"
        echo "  check — that is precisely the false green this assertion replaces."
        rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb plan_tmp_*.txt
        exit 1
    fi
    # The .rb resolves the same binary; hand it the probed answer rather than
    # letting it re-derive one.
    export TILLANDSIAS_PLAN_BIN="$PLAN_BIN"
    "$PLAN_BIN" --index plan_tmp/index.yaml ready > plan_tmp_ready_before.txt

    # SECOND INVARIANT: archiving must not ORPHAN live fragment events.
    #
    # The first real sweep passed the ready-set assertion and still broke the
    # build: 569 rows archived, and check-fragment-status-loss.sh went red with
    # 38 "an events block addresses it but NO SUCH PACKET is in the fold ...
    # that event was discarded". Archiving a row silently drops every
    # plan/index.d event still aimed at it. Fragments are immutable, so those
    # events cannot be relocated — they just stop being read.
    #
    # Compared BEFORE vs AFTER rather than asserted absolutely, because a
    # fragment may already address a packet id that never existed (a typo); the
    # existing advisory tolerates those. What must not happen is the sweep
    # CREATING new ones.
    _orphans() {   # $1 = index path, $2 = output file
        "$PLAN_BIN" --index "$1" query --limit 0 2>/dev/null \
            | cut -f1,2 | tr '\t' '\n' | sed '/^$/d' | sort -u > plan_tmp_live.txt
        comm -23 plan_tmp_addressed.txt plan_tmp_live.txt > "$2"
    }
    : > plan_tmp_addressed_raw.txt
    for _frag in plan_tmp/index.d/*.yaml; do
        [ -e "$_frag" ] || continue
        if ! "$PLAN_BIN" fragment-event-packets "$_frag" >> plan_tmp_addressed_raw.txt 2>/dev/null; then
            echo "Check FAILED: cannot read fragment $_frag, so the orphan invariant"
            echo "  cannot be evaluated. Refusing."
            rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb plan_tmp_*.txt
            exit 1
        fi
    done
    sort -u plan_tmp_addressed_raw.txt > plan_tmp_addressed.txt
    _orphans plan_tmp/index.yaml plan_tmp_orphans_before.txt

    _ruby scripts/archive-plan-packets-check.rb >/dev/null

    _orphans plan_tmp/index.yaml plan_tmp_orphans_after.txt
    if ! diff -u plan_tmp_orphans_before.txt plan_tmp_orphans_after.txt > plan_tmp_orphans_diff.txt; then
        echo "Check FAILED: archiving ORPHANED live fragment events. These packet ids are"
        echo "  addressed by a plan/index.d events block that the fold will now DISCARD:"
        grep '^+[^+]' plan_tmp_orphans_diff.txt | sed -n '1,40p'
        rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb plan_tmp_*.txt
        exit 1
    fi

    "$PLAN_BIN" --index plan_tmp/index.yaml ready > plan_tmp_ready_after.txt
    if ! diff -u plan_tmp_ready_before.txt plan_tmp_ready_after.txt > plan_tmp_ready_diff.txt; then
        echo "Check FAILED: archiving CHANGED THE READY SET. These rows are schedulable"
        echo "  work that the archive swallowed; they will answer 'no packet matches':"
        sed -n '1,40p' plan_tmp_ready_diff.txt
        rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb \
               plan_tmp_ready_before.txt plan_tmp_ready_after.txt plan_tmp_ready_diff.txt
        exit 1
    fi
    rm -f plan_tmp_*.txt

    cp -a plan_tmp/ plan_tmp_bak/
    
    _ruby scripts/archive-plan-packets-check.rb >/dev/null
    
    if ! diff -qr plan_tmp/ plan_tmp_bak/ > /dev/null; then
        echo "Check failed: second run modified files. Not idempotent."
        rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb plan_tmp_*.txt
        exit 1
    fi
    rm -rf plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb plan_tmp_*.txt

    # THIRD INVARIANT: archiving must not break what the expert system can ANSWER.
    #
    # The two assertions above are about ROWS — which ones move, and which
    # events still reach them. Both were green on 2026-08-20 while the sweep
    # shipped a capability loss: 550 archived packets became unanswerable, and
    # `status <id>` and `plan_answer` returned "no packet in the ledger matches
    # any token" for every one of them. Seven tests in `-p tillandsias-plan
    # --lib` were red the whole time. A ledger-SHAPE assertion looks at the
    # ledger; that defect lived in the query engine's reach over it, and no
    # amount of row-checking here can see it.
    #
    # So the last thing this check asks is the only question that closes that
    # gap: after the sweep, does the crate's own suite still pass? Delegated
    # rather than inlined because the answer requires a full tree copy and a
    # cargo run — see the script's header for why it is a tree and not a plan/.
    echo "Checking the sweep does not break what the expert system can answer..."
    if ! _answerability="$("$DIR/check-archive-answerability.sh")"; then
        echo "Check FAILED: the sweep leaves the plan expert unable to answer about"
        echo "  archived work. This is the 2026-08-20 regression; the ready set and"
        echo "  the orphan count above are both clean and cannot see it."
        echo "  $_answerability"
        exit 1
    fi
    echo "  $_answerability"

    echo "Check passed: ready set unchanged, no new orphaned events, archived packets stay answerable, and the script is idempotent."
    exit 0
fi

if ! PLAN_BIN="$(resolve_plan_binary)"; then
    echo "refused:no-plan-binary: the archiver decides closure from the FOLD, which"
    echo "  requires a runnable tillandsias-plan. Refusing rather than archiving from"
    echo "  the base index alone — that silently eats reopened rows."
    exit 1
fi
export TILLANDSIAS_PLAN_BIN="$PLAN_BIN"

_ruby scripts/archive-plan-packets.rb
