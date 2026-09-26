#!/usr/bin/env bash
# @trace spec:ci-release, plan 792-ksr8
#
# check-sigpipe-verdict-pipelines-added.sh — refuse a NEWLY ADDED pipeline
# whose verdict can be decided by SIGPIPE instead of by the question it asks.
#
# THE DEFECT (measured 2026-08-17; four agents blocked by it in one night).
#
#   producer | grep -q PATTERN          under `set -o pipefail`
#
# `grep -q` exits the instant it matches and closes the pipe. The producer,
# still writing, dies of SIGPIPE (141). `pipefail` promotes 141 to the
# PIPELINE's status — even though grep MATCHED. A successful match therefore
# reads as a failure, intermittently.
#
# Reproduced deterministically (scripts/test-sigpipe-verdict-pipelines.sh):
# a 200k-line producer into `grep -qx` for the FIRST line fails 40/40 with
# pipefail on; the same match at the LAST line fails 0/20; the same early
# match with pipefail off fails 0/20.
#
# Live cost: `scripts/check-litmus-pin-claims.sh`, a PUSH-BLOCKING gate,
# returned 1, 2, 3, 4, 5, 6, 13 and 27 violations on UNCHANGED trees — every
# one false — until it was fixed.
#
# WHY DIFF-SCOPED, AND WHY THAT IS THE ONLY HONEST SHAPE HERE.
#
# The whole-repo sweep that produced this gate is the argument for its scope.
# 355 pipelines in this tree feed an early-exiting consumer; ~50 sit in a
# verdict context. Nearly all are BENIGN, because the race needs the producer
# to still be writing when the consumer exits, and the dominant idiom is
# `printf '%s' "$short_var" | grep -q`, whose producer emits a SHA or a branch
# name. MEASURED size discriminator on this host: 0 false failures below ~6 KB
# of producer output, mixed between 8-14 KB, essentially certain above ~19 KB.
#
# Producer SIZE is what decides the defect, and it is not statically
# decidable. Every proxy leaks in both directions, and the sweep proved both:
#   * A whole-repo run keyed on "unbounded-looking producer" flagged four
#     legacy sites (`rustup target list --installed`, `git config --get-all
#     <one key>`) whose real output here is 144 and 18 BYTES — false positives.
#   * The two genuinely exploitable sites found in the sweep
#     (check-windows-tray-diagnose-surface.sh, check-windows-only-sources-
#     verified.sh — both piping a whole `cargo test` transcript) are
#     `printf '%s' "$var"` producers, which no static producer list catches.
# A whole-repo GATE would therefore cry wolf on safe code while missing the
# real cases, which is precisely the false-signal failure 741-2izr says is as
# damaging as no signal at all.
#
# Diff scoping removes that trade-off, following the 634-39ik precedent
# (check-litmus-expression-pinning-added.sh): the legacy corpus is never
# scanned, so there is no standing false-positive burden, and an author adding
# a NEW pipeline of this shape can use the safe idiom for free or record a
# one-line exemption. Enforcement only ever ADDS, so an unavailable base ref
# skips rather than refuses — same polarity as 634-39ik, and deliberately the
# opposite of a scoping guard that REMOVES coverage.
#
# SAFE REWRITES (all bash-3.2 clean, all cheaper than the pipe):
#   membership in a list  ->  case $'\n'"$list"$'\n' in *$'\n'"$x"$'\n'*)
#   pattern in a variable ->  grep -q PATTERN <<<"$var"
#   pattern in a command  ->  out="$(cmd)"; grep -q PATTERN <<<"$out"
#
# Escape hatch: append `# sigpipe-ok: <reason>` to the line. Per-line and
# reason-bearing, so an exemption is a recorded decision, not a silent one.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:sigpipe-verdict-added:[0-9]+ checked|ok:sigpipe-verdict-added:base-unavailable|violation:sigpipe-verdict-added:[0-9]+)$
#
# Pinned by litmus:sigpipe-verdict-pipeline-shape.

set -uo pipefail

# Root is overridable so the fixture can drive this against a throwaway repo
# with a real base ref. Without the seam every fixture case silently returned
# base-unavailable and "passed" vacuously — caught by the mutation case, which
# is the argument for having one.
REPO_ROOT="${TILLANDSIAS_SIGPIPE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO_ROOT" || exit 2

base_ref="${TILLANDSIAS_SIGPIPE_BASE:-origin/linux-next}"

if ! git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
    echo "ok:sigpipe-verdict-added:base-unavailable"
    echo "  note: base ref '$base_ref' unavailable — added-line enforcement skipped" >&2
    exit 0
fi

# Producers whose output is unbounded BY NATURE. Deliberately excludes
# bounded-by-construction queries the sweep proved safe (`git config
# --get-all <key>` = 18 bytes here, `rustup target list --installed` = 144).
# ORDER 1070-a4gc: A PLAIN RECURSIVE GREP IS AN UNBOUNDED PRODUCER.
#
# This list recognised `git grep` and not `grep -r`, so the exact line that
# broke the trace-coverage metric was invisible to this guard even when NEWLY
# added. In validate-traces.sh, `grep -rl ... | grep -q .` under pipefail made
# `grep -q` close the pipe, the still-traversing `grep -rl` take SIGPIPE and
# return 141, pipefail propagate it, and the `if` take the else branch — so the
# three best-traced specs were reported UNCOVERED and the fleet's coverage
# number was wrong and host-dependent (1069-c9w6).
#
# `[rR]` anywhere in the flag cluster with `[a-zA-Z]*` on BOTH sides, so `-rl`,
# `-rn`, `-R` and `-lr` all match. The first cut wrote `-[a-zA-Z]*[rR]` and
# required whitespace immediately after, which matches `-r` and `-lr` but NOT
# `-rl` — the exact flag combination in the defect this order exists for. The
# fixture caught it, and it is the same trailing-boundary mistake as a prefix
# that matches a longer identifier. A NON-recursive grep is deliberately NOT a producer here: it is bounded
# by its input file, and adding bare `grep` would flag the common and harmless
# `grep x file | grep -q y`.
#
# `rg` IS NOT ADDED, and that is a measurement rather than an oversight.
# ripgrep is recursive by default, so every use as a producer is unbounded — but
# this guard tests the whole text left of the pipe, and `command -v rg && ...`
# appears in scripts/with-tillandsias-builder.sh:247, which would be flagged as
# a false positive on correct code. Live producer instances of rg: zero. When
# one appears, add it with an anchor that distinguishes a command from an
# argument.
# ORDER 1084-nzqc — ESCAPE 1: AN ABSOLUTE PATH IS STILL THE COMMAND.
# The anchor used to be `(^|[;&|(]|[[:space:]])` alone, so in `/usr/bin/grep`
# the character before `grep` is `/` and the producer did not match. That is not
# a hypothetical spelling: scripts/validate-traces.sh calls `/usr/bin/grep`
# EIGHT times, deliberately, so macOS gets BSD grep regardless of Homebrew, and
# 35 occurrences across 9 files under scripts/ were invisible for the same
# reason. `(/[^[:space:]|;&()]*)?` admits an optional path prefix -- /usr/bin/,
# /bin/, or any absolute path -- while still requiring the delimiter before it,
# so `foogrep` and `mygit` remain unmatched.
UNBOUNDED_PRODUCER_RE='(^|[;&|(]|[[:space:]])(/[^[:space:]|;&()]*/)?(cat|find|journalctl|coredumpctl|grep[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*|git[[:space:]]+(log|diff|show|ls-files|ls-tree|grep)|cargo|podman[[:space:]]+(logs|events|ps|images)|docker[[:space:]]+(logs|ps|images))([[:space:]]|$)'

# ORDER 1307-ermc — A printf/echo OF A VARIABLE IS A PRODUCER OF UNKNOWN SIZE.
#
# THIS OVERTURNS A DOCUMENTED DECISION RATHER THAN FILLING A GAP, so the
# disproof is recorded here beside it. The header above says the dominant idiom
# is `printf '%s' "$short_var" | grep -q`, "whose producer emits a SHA or a
# branch name", and that the two genuinely exploitable sites found in the
# August sweep were `printf '%s' "$var"` producers "which no static producer
# list catches". Both halves were true and the conclusion — leave the class out
# — held for five weeks.
#
# THE DISPROOF IS 1306-ifhv, measured on yoga 2026-09-20. The flaking line was
# `printf '%s' "$out" | grep -qi 'ANCESTRY IS NOT USED' && ok … || bad …` in
# scripts/test-salvage-audit.sh. `$out` was a captured audit transcript of
# 15,569 BYTES. Under a default 64 KB pipe it fits one write and never flakes,
# which is why forty replays were clean; under the 8,192-byte pipes a loaded
# host hands out once its open pipes pass /proc/sys/fs/pipe-user-pages-soft it
# needs two, and it flaked 2 in 20. So "the benign shape is small" is not a
# property of the shape. It is a property of the VARIABLE, and the variable is
# not visible from the text.
#
# WHY BROAD AND NOT NARROW. A rule that flagged only "large" variables would
# need to know what a variable holds, which a text checker cannot; the honest
# candidate was a variable-provenance test (was it assigned from a command
# substitution of an unbounded command), and it was not attempted because the
# breadth turned out to be cheap enough not to need it. MEASURED: 9 added lines
# in 7 days fleet-wide come into scope from this plus the and-or admission
# together. This guard is DIFF-SCOPED, so the legacy corpus is never asked;
# only new lines pay, and they pay either one `# sigpipe-ok: <reason>` or a
# `<<<` rewrite that removes the hazard entirely.
PRODUCER_UNKNOWN_SIZE_RE='(^|[;&|(]|[[:space:]])(printf|echo)([[:space:]]|$)[^|]*"\$'

# Consumers that stop reading before EOF.
EARLY_EXIT_CONSUMER_RE='\|[[:space:]]*(grep[[:space:]]+[^|]*-[a-zA-Z]*q|grep[[:space:]]+[^|]*-m[[:space:]]*1|head[[:space:]]|sed[[:space:]]+-n?[[:space:]]*.?[0-9]*q)'

# Contexts where the pipeline's status becomes a verdict.
#
# ORDER 1307-ermc — THE AND-OR SPELLING IS A VERDICT CONTEXT AND WAS NOT LISTED.
# `producer | grep -q pat && ok "..." || bad "..."` reads the pipeline's status
# exactly as `if !` does: under pipefail the status is 141 with the pattern
# PRESENT, `&&` is skipped and `|| bad` fires on a successful match. This regex
# anchors on a LEADING keyword, so that spelling was never a verdict context
# here at all — not a pattern that was too narrow, a shape that was absent.
#
# MEASURED COST OF ADMITTING IT, on origin/linux-next over the 7 days to
# 2026-09-20, counting lines ADDED to scripts/*.sh and build.sh: 22,117 added
# lines, 167 with an early-exit grep -q, 19 with `&&`/`||` after that consumer,
# 16 also carrying a printf/echo-of-a-variable producer — of which 7 were
# ALREADY an if/while/until/elif context, leaving NINE that this change newly
# brings into scope. Nine in a week, fleet-wide. An author meeting one writes
# `grep -q PAT <<<"$var"`, which cannot SIGPIPE at all, or one `# sigpipe-ok:`.
VERDICT_CONTEXT_RE='^[[:space:]]*(if[[:space:]]|while[[:space:]]|until[[:space:]]|elif[[:space:]])'

# _is_verdict_context <logical-line> — true when the pipeline's status decides
# something. Two spellings, and the second cannot be a leading-anchor regex:
# what makes it a verdict is that `&&` or `||` follows the CONSUMER, so the
# position of the consumer has to be known first.
_is_verdict_context() {
    local line="$1" after
    case "$line" in
        # Leading-keyword spelling, unchanged since 792-ksr8.
        [[:space:]]*if\ *|if\ *|[[:space:]]*while\ *|while\ *|\
        [[:space:]]*until\ *|until\ *|[[:space:]]*elif\ *|elif\ *) return 0 ;;
    esac
    # And-or spelling: strip up to and including the early-exiting consumer,
    # then look for a branch in what remains.
    after="$(printf '%s' "$line" | sed -E "s/.*${EARLY_EXIT_CONSUMER_RE}//")"  # sigpipe-ok: sed consumes its whole input; no early exit, no SIGPIPE
    [ "$after" = "$line" ] && return 1
    case "$after" in *'&&'*|*'||'*) return 0 ;; esac
    return 1
}

file_sets_pipefail() {
    grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*o[[:space:]]+pipefail' "$1" 2>/dev/null
}

checked=0
violations=0

while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    case "$f" in
        *.sh|build.sh) ;;
        *) continue ;;
    esac
    file_sets_pipefail "$f" || continue

    # ORDER 1084-nzqc — ESCAPE 2: A PIPELINE SPLIT ACROSS `\` CONTINUATIONS.
    #
    # This loop read ONE ADDED LINE AT A TIME, and VERDICT_CONTEXT_RE anchors on
    # a leading if/while/until/elif. A pipeline written across continuations puts
    # the verdict context on the FIRST physical line and the early-exiting
    # consumer on the LAST, so no single line carries both and the conjunction
    # below could never be satisfied. A census found 155 verdict-context lines
    # ending in a continuation under scripts/ -- an upper bound, but the order of
    # the blind spot.
    #
    # FOLDED FROM THE FILE, NOT FROM THE DIFF, and that is the safe half. Joining
    # the diff's added-line stream would splice lines that are not adjacent in
    # the file whenever a hunk adds only part of a continuation, and fabricate a
    # pipeline nobody wrote. Instead the FILE is folded into logical lines, and a
    # logical line is in scope when ANY of its physical lines was added -- which
    # is also the more faithful reading of "added in this change".
    _added_f="$(mktemp "${TMPDIR:-/tmp}/sigpipe-added.XXXXXX")" || continue
    # ORDER 1391-8ikx: an UNTRACKED file has no diff against the base; every
    # line of it is added in this change.
    if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
        git diff "$base_ref" -- "$f" 2>/dev/null | sed -n 's/^+//p' > "$_added_f"
    else
        cat -- "$f" > "$_added_f"
    fi
    # A diff of a deleted or renamed-away file adds nothing; skip without cost.
    if [ ! -s "$_added_f" ]; then rm -f "$_added_f"; continue; fi
    # ORDER 1391-8ikx: `checked` counts the files EXAMINED, so ok:...:0 can only
    # mean nothing was in scope. It used to move only on a violation, so every
    # ok read 0 whether one file or fifty had been read.
    checked=$((checked + 1))

    _logical=""      # the folded line being accumulated
    _touched=0       # 1 when one of its physical lines was added
    while IFS= read -r _phys || [ -n "$_phys" ]; do
        if [ -n "$_logical" ]; then
            # Continuations are joined with a single space: the regexes are
            # whitespace-tolerant and this keeps `\` out of the matched text.
            _logical="$_logical ${_phys#"${_phys%%[![:space:]]*}"}"
        else
            _logical="$_phys"
        fi
        if grep -Fxq -- "$_phys" "$_added_f" 2>/dev/null; then _touched=1; fi
        case "$_logical" in
            *'\') _logical="${_logical%\\}"; continue ;;
        esac

        added="$_logical"; _logical=""
        _was_touched="$_touched"; _touched=0
        [ "$_was_touched" -eq 1 ] || continue
        [ -n "$added" ] || continue
        case "$added" in
            *"sigpipe-ok:"*) continue ;;
        esac
        # THESE FOUR LINES ARE THIS ORDER'S OWN SPECIMEN (1307-ermc). Until this
        # change they were three instances of the and-or spelling with a
        # printf-of-a-variable producer — the exact pair of properties being
        # admitted below — inside the guard that exists to find them. They are
        # BENIGN for the documented reason: `$added` is ONE logical line, so the
        # producer completes in a single write and the reader never wins the
        # race. That is the order's whole argument in four lines: the shape is
        # idiomatic and unavoidable, a whole-repo rule would flag this file
        # three times, and SIZE is the discriminator rather than shape.
        #
        # They are rewritten to the `<<<` form rather than annotated. An
        # exemption would have been honest and cheaper; the rewrite is better
        # because a here-string cannot SIGPIPE AT ALL, so the question stops
        # being asked instead of being answered every time someone reads it.
        _is_verdict_context "$added" || continue
        grep -qE "$EARLY_EXIT_CONSUMER_RE" <<<"$added" || continue
        producer="${added%%|*}"
        if ! grep -qE "$UNBOUNDED_PRODUCER_RE" <<<"$producer"; then
            grep -qE "$PRODUCER_UNKNOWN_SIZE_RE" <<<"$producer" || continue
        fi

        violations=$((violations + 1))
        echo "REFUSED: $f — this change ADDS a verdict pipeline that SIGPIPE can decide:" >&2
        echo "         $(printf '%s' "$added" | sed 's/^[[:space:]]*//' | cut -c1-100)" >&2
        echo "         An unbounded producer feeds an early-exiting consumer under pipefail," >&2
        echo "         so a MATCH can surface as a failure. Capture first, or use a" >&2
        echo "         here-string: grep -q PATTERN <<<\"\$var\"" >&2
        echo "         Reviewed and genuinely bounded? append: # sigpipe-ok: <reason>" >&2
    done < "$f"
    rm -f "$_added_f"
done <<EOF
$(
    # ORDER 1391-8ikx: the population is the change, INCLUDING untracked files.
    # `git diff --name-only <base>` never lists an untracked file, so a
    # brand-new script was invisible until staged and the gate answered ok
    # over an empty population (measured twice on 2026-09-26).
    { git diff --name-only "$base_ref" 2>/dev/null
      git ls-files --others --exclude-standard 2>/dev/null; } | LC_ALL=C sort -u
)
EOF

if [ "$violations" -gt 0 ]; then
    echo "violation:sigpipe-verdict-added:$violations"
    echo "This check is diff-scoped — it flags ONLY pipelines added in this change, never the existing corpus." >&2
    exit 1
fi
echo "ok:sigpipe-verdict-added:$checked checked"
exit 0
