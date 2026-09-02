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
# ORDER 965-sxec: a failed ensure is a DEGRADED lane, not the verdict.
# `set -e` plus a sourced script that `return 1`s killed this one with rc=1
# before the ruby probe below could run — so a host with a broken toolbox got
# the same uninterpretable exit as a real ledger violation, one layer above the
# 127 this order is about. ensure_toolbox is an ACCELERATOR (it makes the
# toolbox lane available); whether ruby is USABLE is decided by _ruby_usable(),
# by execution, and that is the question the caller actually needs answered.
# Keep the ensure's stderr — it is the diagnosis when the toolbox lane is why
# ruby is unreachable.
source "$DIR/ensure_toolbox.sh" || true
# 704-zcgi. The .rb now asks the FOLD which packets are terminal instead of
# grepping the base index, so this script has a hard tillandsias-plan
# dependency too — resolved by execution, through the one shared probe.
source "$DIR/plan-binary-probe.sh"
# ORDER 964-9yyp. Where this check's scratch copies land. See the file for the
# measurement; the short version is that --check copies plan/, rewrites the
# copy, copies it again and diffs the two trees, so it is metadata- and
# write-bound, and on the Windows gate's 9p checkout that costs 11.7x.
source "$DIR/native-scratch-dir.sh"
_ruby() {
    # -E UTF-8:UTF-8 pins Ruby's default external/internal encodings. On an
    # unset-locale host (measured 2026-08-23: the WSL lane the Windows gate
    # runs in has LANG/LC_ALL empty) default_external is US-ASCII, and the
    # ledger's first em-dash kills String#match? with "invalid byte sequence
    # in US-ASCII". The ledger is UTF-8 by construction; zero behavior change
    # where the locale already says so.
    # ORDER 965-sxec. Gate on USABILITY, and dispatch on the lane the probe
    # actually confirmed — not on `command -v`, which a brew shim satisfies
    # without providing a ruby. Testing PATH here and the toolbox there could
    # disagree: a forge with a shim named `ruby` and no working toolbox would
    # take the native branch and exit 127, which is the defect. Placing the
    # gate INSIDE _ruby means no call site can forget it (three call sites
    # today), and the probe is memoised so the cost is paid once.
    _require_ruby
    if [ "$_RUBY_LANE" = "native" ]; then
        ruby -E UTF-8:UTF-8 "$@"
    else
        # ORDER 923-ws3r — FORWARD THE NAMESPACE ACROSS THIS BOUNDARY.
        #
        # `toolbox run` does NOT forward the caller's environment. This call
        # site is a hand-rolled dispatch that never learned what
        # scripts/with-tillandsias-builder.sh already says in as many words
        # ("every TILLANDSIAS_* control flag silently died at this boundary"),
        # and scripts/with-wsl2-builder.sh repeats for WSL. Same lesson, third
        # boundary — the 704-zcgi shape.
        #
        # WHAT IT COST, measured on yoga 2026-08-29. The archiver's Ruby half
        # reads `plan_bin = ENV['TILLANDSIAS_PLAN_BIN'] || 'target/release/…'`.
        # Both this script and check-archive-answerability.sh export that var
        # with an ABSOLUTE path, correctly — and it died here, so the .rb fell
        # back to the RELATIVE default. Inside the answerability check's
        # hermetic tree (which excludes ./target by design) that path does not
        # exist, so `archive-plan-packets.sh --check` has been RED on a clean
        # checkout, blocking nothing but reported by every host.
        #
        # It is worse in the ordinary case, where the relative path happens to
        # exist: the .rb then silently runs a DIFFERENT binary than the caller
        # resolved — the freshness probe's answer discarded, and a stale
        # ./target artifact deciding which packets are terminal.
        #
        # `toolbox run` has no --env (checked), so the exports are built into
        # the command string exactly as both precedents do it.
        _ar_env=""
        while IFS= read -r _ar_var; do
            _ar_env="${_ar_env}export $(printf '%q' "$_ar_var")=$(printf '%q' "${!_ar_var}") ; "
        done < <(compgen -v | grep '^TILLANDSIAS_' || true)
        _ar_args=""
        for _ar_a in "$@"; do
            _ar_args="$_ar_args$(printf '%q ' "$_ar_a")"
        done
        toolbox run --container tillandsias-builder \
            bash -lc "${_ar_env}cd $(printf '%q' "$PWD") && exec ruby -E UTF-8:UTF-8 $_ar_args"
    fi
}


# ── ORDER 965-sxec: RUBY MUST BE USABLE, NOT MERELY ON PATH ──────────────────
#
# `command -v ruby` is not a usability test inside a forge. The image ships NO
# ruby and puts an on-demand brew SHIM on PATH under that name, so `command -v`
# succeeds, the shim attempts a userspace install, the install fails by design
# (attestation verification is REQUIRED and no GitHub credential may exist in a
# forge), and the shim exits 127.
#
# 127 is the defect. build.sh already draws the right distinction — it maps
# rc==3 to "the archiver's check COULD NOT RUN ... the instrument is what needs
# repair (923-ws3r)" — but 127 misses that branch and falls through to the
# `-ne 0` arm, which prints:
#
#     the plan archiver would CHANGE THE READY SET, orphan events, or leave
#     archived rows unanswerable — do not sweep
#
# That is a substantive claim about the LEDGER, asserted on the strength of a
# command that never executed. An agent reading it goes hunting for ledger
# damage that does not exist. MEASURED on lenovinha-tillandsias-forge
# 2026-09-02: `scripts/archive-plan-packets.sh --check` -> rc=127, and the gate
# reported ledger corruption.
#
# So probe by EXECUTION, exactly as 704-zcgi/721-nyev require for the plan
# binary two blocks below, and for the same reason: an executable bit — or a
# name on PATH — is not the property being asked about. The probe is a trivial
# program, bounded, with output discarded; a real ruby answers in milliseconds
# and a shim fails immediately now that the 966-rq7f re-entrancy guard stops it
# recursing.
#
# MEMOISED for the process lifetime. Before 966-rq7f each shim hit forked a
# fresh `brew install ruby`, and a single `--check` reached 3663 processes and
# 89.4% of the pid ceiling on pirria — the container then failed to fork at all
# and the symptom surfaced as `git: unable to create threaded lstat`, nowhere
# near its cause. The guard fixed the recursion; this memo makes sure a caller
# that probes repeatedly still pays exactly one acquisition attempt.
_RUBY_LANE=""
_ruby_usable() {
    if [ -n "$_RUBY_LANE" ]; then
        [ "$_RUBY_LANE" != "none" ]
        return
    fi
    _RUBY_LANE="none"
    if command -v ruby >/dev/null 2>&1 \
        && TILLANDSIAS_BREW_AUTOINSTALL=0 timeout 30 ruby -e 'exit 0' >/dev/null 2>&1; then
        _RUBY_LANE="native"
    elif command -v toolbox >/dev/null 2>&1 \
        && timeout 60 toolbox run --container tillandsias-builder \
            ruby -e 'exit 0' >/dev/null 2>&1; then
        # The toolbox lane _ruby() falls back to. A host with no native ruby but
        # a working builder toolbox is fully supported and must not be refused.
        _RUBY_LANE="toolbox"
    fi
    [ "$_RUBY_LANE" != "none" ]
}

# Refuse into the could-not-run channel rather than letting a 127 masquerade as
# a ledger verdict. Callers that only need the archiver's OTHER halves never
# reach this; it guards the ruby-dependent paths.
_require_ruby() {
    _ruby_usable && return 0
    echo "Check FAILED: no usable ruby in this locus, so the archiver's ready-set" >&2
    echo "  and orphan-event invariants CANNOT BE EVALUATED. This says NOTHING" >&2
    echo "  about the ledger — the instrument is missing, not the data (923-ws3r)." >&2
    echo "  Inside a forge this is expected: the image ships no ruby and the brew" >&2
    echo "  shim cannot install one without a GitHub credential (965-sxec)." >&2
    echo "  Remedy: run this check on a host with ruby or a tillandsias-builder" >&2
    echo "  toolbox, or rebuild the forge image with ruby present." >&2
    exit 3
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
    # ORDER 964-9yyp: the scratch may live outside the worktree now, and the
    # trap has to reach it there. `${SCRATCH:-$REPO_ROOT}` because this trap is
    # armed before SCRATCH is assigned on some paths and an unbound expansion
    # under `set -u` would turn a cleanup into a second failure.
    local _s="${SCRATCH:-$REPO_ROOT}"
    rm -rf "$_s"/plan_tmp "$_s"/plan_tmp_bak scripts/archive-plan-packets-check.rb "$_s"/plan_tmp_*.txt
}

if [ "$1" == "--check" ]; then
    # ORDER 964-js34: per-phase profile, opt-in and zero-cost when off.
    _ap_t0=0; _ap_last=0
    # BSD date SUCCEEDS on %3N and emits a literal "N", so an exit-code guard
    # cannot catch it (761-g36m). Digit-validate, then degrade to whole
    # seconds — this feeds a profile line only.
    _ap_now() {
        local _t
        _t="$(date +%s%3N 2>/dev/null || true)" # gnu-date: ok (digit-validated below)
        case "$_t" in '' | *[!0-9]*) _t="$(date +%s 2>/dev/null || echo 0)000" ;; esac
        printf '%s' "$_t"
    }
    _ap_phase() {
        [ -n "${TILLANDSIAS_ARCHIVER_PROFILE:-}" ] || return 0
        local _n; _n=$(_ap_now)
        [ "$_ap_last" = 0 ] && { _ap_t0=$_n; _ap_last=$_n; return 0; }
        printf '[archiver-profile] %-28s %6sms\n' "$1" "$((_n - _ap_last))" >&2
        _ap_last=$_n
    }
    _ap_total() {
        [ -n "${TILLANDSIAS_ARCHIVER_PROFILE:-}" ] || return 0
        printf '[archiver-profile] %-28s %6sms\n' TOTAL "$(( $(_ap_now) - _ap_t0 ))" >&2
    }
    _ap_phase start
    echo "Running in check mode..."
    # ORDER 964-9yyp. On a fast worktree this is "$REPO_ROOT" and every path
    # below is byte-for-byte what it was — a host that was correct before this
    # order behaves identically after it. On the Windows gate's 9p checkout it
    # is a native-FS directory, and the check drops from 62.3s to 5.3s doing
    # exactly the same work. It also stops the copy landing in the worktree,
    # which is the leak the cleanup trap above exists to survive.
    SCRATCH="$(native_scratch_dir archiver-check "$REPO_ROOT")"
    trap _archiver_cleanup EXIT INT TERM
    rm -rf "$SCRATCH"/plan_tmp "$SCRATCH"/plan_tmp_bak
    cp -a plan/ "$SCRATCH"/plan_tmp/
    _ap_phase copy-plan-tree
    
    # The generated .rb reads and writes the COPY, so it needs the copy's real
    # location. `|` stays the delimiter because the replacement is a path and
    # contains no `|`; it is a directory name we chose, not user input.
    sed "s|plan/|$SCRATCH/plan_tmp/|g" scripts/archive-plan-packets.rb > scripts/archive-plan-packets-check.rb
    _ap_phase sed-rewrite-rb

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
    # ── ORDER 923-ws3r: EXIT 3 MEANS "COULD NOT RUN" ────────────────────────
    #
    # --check exits 1 when an INVARIANT IS VIOLATED (the ready set moved, events
    # were orphaned, archived rows stopped answering, the sweep is not
    # idempotent) and 3 when it COULD NOT EVALUATE one (no runnable binary, a
    # stale one, an unreadable fragment, a harness that could not start).
    #
    # They were one exit code behind one caller message — "the plan archiver
    # would change the ready set, or its check could not run" — which is a
    # sentence nobody can act on. The two demand opposite responses: a violation
    # means STOP, do not sweep; a could-not-run means the INSTRUMENT is broken
    # and the sentence says nothing about the ledger. This check was red on a
    # clean checkout for days for the second reason while its message invited
    # every reader to assume the first.
    # 851-cduu: ensure, not resolve. On this exact call site the Windows gate
    # (executing in WSL against a CARGO_TARGET_DIR preflight never rebuilds)
    # consulted a 6-day-stale binary. Freshness is verified HERE, in the locus
    # about to consume the answer; the fresh case costs a no-op cargo build.
    PLAN_BIN="$(ensure_fresh_plan_binary)" && _fresh_rc=0 || _fresh_rc=$?
    if [ "$_fresh_rc" -eq 2 ]; then
        echo "Check FAILED: the resolved tillandsias-plan is STALE for this tree and"
        echo "  could not be rebuilt in this locus (851-cduu). A stale instrument does"
        echo "  not fail; it answers wrong — refusing to evaluate the ready-set"
        echo "  invariant with a binary built for another checkout."
        exit 3
    elif [ "$_fresh_rc" -ne 0 ]; then
        echo "Check FAILED: no runnable tillandsias-plan, so the ready-set invariant"
        echo "  cannot be evaluated. Refusing to fall back to the idempotency-only"
        echo "  check — that is precisely the false green this assertion replaces."
        exit 3
    fi
    # The .rb resolves the same binary; hand it the probed answer rather than
    # letting it re-derive one.
    export TILLANDSIAS_PLAN_BIN="$PLAN_BIN"
    "$PLAN_BIN" --index "$SCRATCH"/plan_tmp/index.yaml ready > "$SCRATCH"/plan_tmp_ready_before.txt
    _ap_phase ready-before

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
            | cut -f1,2 | tr '\t' '\n' | sed '/^$/d' | sort -u > "$SCRATCH"/plan_tmp_live.txt
        comm -23 "$SCRATCH"/plan_tmp_addressed.txt "$SCRATCH"/plan_tmp_live.txt > "$2"
    }
    : > "$SCRATCH"/plan_tmp_addressed_raw.txt
    for _frag in "$SCRATCH"/plan_tmp/index.d/*.yaml; do
        [ -e "$_frag" ] || continue
        if ! "$PLAN_BIN" fragment-event-packets "$_frag" >> "$SCRATCH"/plan_tmp_addressed_raw.txt 2>/dev/null; then
            echo "Check FAILED: cannot read fragment $_frag, so the orphan invariant"
            echo "  cannot be evaluated. Refusing."
            _archiver_cleanup
            exit 3
        fi
    done
    sort -u "$SCRATCH"/plan_tmp_addressed_raw.txt > "$SCRATCH"/plan_tmp_addressed.txt
    _orphans "$SCRATCH"/plan_tmp/index.yaml "$SCRATCH"/plan_tmp_orphans_before.txt
    _ap_phase orphans-before

    _ruby scripts/archive-plan-packets-check.rb >/dev/null
    _ap_phase ruby-sweep

    _orphans "$SCRATCH"/plan_tmp/index.yaml "$SCRATCH"/plan_tmp_orphans_after.txt
    _ap_phase orphans-after
    if ! diff -u "$SCRATCH"/plan_tmp_orphans_before.txt "$SCRATCH"/plan_tmp_orphans_after.txt > "$SCRATCH"/plan_tmp_orphans_diff.txt; then
        echo "Check FAILED: archiving ORPHANED live fragment events. These packet ids are"
        echo "  addressed by a plan/index.d events block that the fold will now DISCARD:"
        grep '^+[^+]' "$SCRATCH"/plan_tmp_orphans_diff.txt | sed -n '1,40p'
        _archiver_cleanup
        exit 1
    fi

    "$PLAN_BIN" --index "$SCRATCH"/plan_tmp/index.yaml ready > "$SCRATCH"/plan_tmp_ready_after.txt
    _ap_phase ready-after
    if ! diff -u "$SCRATCH"/plan_tmp_ready_before.txt "$SCRATCH"/plan_tmp_ready_after.txt > "$SCRATCH"/plan_tmp_ready_diff.txt; then
        echo "Check FAILED: archiving CHANGED THE READY SET. These rows are schedulable"
        echo "  work that the archive swallowed; they will answer 'no packet matches':"
        sed -n '1,40p' "$SCRATCH"/plan_tmp_ready_diff.txt
        _archiver_cleanup
        exit 1
    fi
    rm -f "$SCRATCH"/plan_tmp_*.txt

    cp -a "$SCRATCH"/plan_tmp/ "$SCRATCH"/plan_tmp_bak/
    
    _ruby scripts/archive-plan-packets-check.rb >/dev/null
    _ap_phase ruby-sweep
    
    _ap_phase idempotency-diff
    if ! diff -qr "$SCRATCH"/plan_tmp/ "$SCRATCH"/plan_tmp_bak/ > /dev/null; then
        echo "Check failed: second run modified files. Not idempotent."
        _archiver_cleanup
        exit 1
    fi
    _archiver_cleanup

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
    _ap_phase pre-answerability
    if ! _answerability="$("$DIR/check-archive-answerability.sh")"; then
        # 923-ws3r. The sub-check names its own inability distinctly from a real
        # regression, so relay the distinction instead of flattening it.
        case "$_answerability" in
            *:no-runnable-plan-binary*|*:cannot-create-workdir*|*:sweep-failed*|*:ready-listing-failed*|*:unknown-argument*)
                echo "Check COULD NOT RUN: the answerability harness failed before it could"
                echo "  judge the sweep, so this says NOTHING about the ledger — read its log."
                echo "  $_answerability"
                exit 3
                ;;
        esac
        echo "Check FAILED: the sweep leaves the plan expert unable to answer about"
        echo "  archived work. This is the 2026-08-20 regression; the ready set and"
        echo "  the orphan count above are both clean and cannot see it."
        echo "  $_answerability"
        exit 1
    fi
    echo "  $_answerability"

    _ap_phase answerability
    _ap_total
    echo "Check passed: ready set unchanged, no new orphaned events, archived packets stay answerable, and the script is idempotent."
    exit 0
fi

if ! PLAN_BIN="$(resolve_plan_binary)"; then
    echo "refused:no-plan-binary: the archiver decides closure from the FOLD, which"
    echo "  requires a runnable tillandsias-plan. Refusing rather than archiving from"
    echo "  the base index alone — that silently eats reopened rows."
    exit 3
fi
export TILLANDSIAS_PLAN_BIN="$PLAN_BIN"

_ruby scripts/archive-plan-packets.rb
