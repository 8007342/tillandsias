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
UNBOUNDED_PRODUCER_RE='(^|[;&|(]|[[:space:]])(cat|find|journalctl|coredumpctl|grep[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*|git[[:space:]]+(log|diff|show|ls-files|ls-tree|grep)|cargo|podman[[:space:]]+(logs|events|ps|images)|docker[[:space:]]+(logs|ps|images))([[:space:]]|$)'

# Consumers that stop reading before EOF.
EARLY_EXIT_CONSUMER_RE='\|[[:space:]]*(grep[[:space:]]+[^|]*-[a-zA-Z]*q|grep[[:space:]]+[^|]*-m[[:space:]]*1|head[[:space:]]|sed[[:space:]]+-n?[[:space:]]*.?[0-9]*q)'

# Contexts where the pipeline's status becomes a verdict.
VERDICT_CONTEXT_RE='^[[:space:]]*(if[[:space:]]|while[[:space:]]|until[[:space:]]|elif[[:space:]])'

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

    while IFS= read -r added; do
        [ -n "$added" ] || continue
        case "$added" in
            *"sigpipe-ok:"*) continue ;;
        esac
        printf '%s' "$added" | grep -qE "$VERDICT_CONTEXT_RE" || continue
        printf '%s' "$added" | grep -qE "$EARLY_EXIT_CONSUMER_RE" || continue
        producer="${added%%|*}"
        printf '%s' "$producer" | grep -qE "$UNBOUNDED_PRODUCER_RE" || continue

        checked=$((checked + 1))
        violations=$((violations + 1))
        echo "REFUSED: $f — this change ADDS a verdict pipeline that SIGPIPE can decide:" >&2
        echo "         $(printf '%s' "$added" | sed 's/^[[:space:]]*//' | cut -c1-100)" >&2
        echo "         An unbounded producer feeds an early-exiting consumer under pipefail," >&2
        echo "         so a MATCH can surface as a failure. Capture first, or use a" >&2
        echo "         here-string: grep -q PATTERN <<<\"\$var\"" >&2
        echo "         Reviewed and genuinely bounded? append: # sigpipe-ok: <reason>" >&2
    done <<EOF
$(git diff "$base_ref" -- "$f" 2>/dev/null | sed -n 's/^+//p')
EOF
done <<EOF
$(git diff --name-only "$base_ref" 2>/dev/null)
EOF

if [ "$violations" -gt 0 ]; then
    echo "violation:sigpipe-verdict-added:$violations"
    echo "This check is diff-scoped — it flags ONLY pipelines added in this change, never the existing corpus." >&2
    exit 1
fi
echo "ok:sigpipe-verdict-added:$checked checked"
exit 0
