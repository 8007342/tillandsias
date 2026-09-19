#!/usr/bin/env bash
# @trace order:1150-q462, spec:ci-release
#
# Fixture for the competing-gate CONSUMER in with-tillandsias-builder.sh.
#
# REGIME: hermetic and offline. Every arm replaces the detector with a STUB that
# exits with a chosen code, and drives the wrapper's case through a tiny harness
# extracted from it. No toolbox, no podman, no /proc scan, nothing timed; it
# asserts nothing about this host.
#
# WHAT IS PINNED IS THE BRANCHING, NOT THE CODES. 1141-vf9w's grammar already has
# its own fixture. This one exists because both call sites read `|| true`, so the
# grammar bound NOBODY: a caller-contract bug (2) and an unsupported substrate
# (3) produced the same observable, and they want opposite responses — "fix your
# call site" versus "this host cannot answer".
#
# THE ARM MOST LIKELY TO BE DELETED AS REDUNDANT is arm 5, and it is the reason
# the row exists: a consumer that merely LOGS both and proceeds passes every
# other arm here. Only "2 and 3 produce DIFFERENT observable responses" catches
# the collapse.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# TILLANDSIAS_CONSUMER_WRAPPER_UNDER_TEST is the mutation-control seam: the
# strict arms below must red on a wrapper that captures the detector with a
# bare assignment under set -e (the shipped form until 2026-09-13).
WRAPPER="${TILLANDSIAS_CONSUMER_WRAPPER_UNDER_TEST:-$ROOT/scripts/with-tillandsias-builder.sh}"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok:   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL: %s\n' "$1"; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# The wrapper's case block, lifted verbatim from the source so this fixture
# cannot drift from what ships. Extracted by markers rather than line numbers:
# a line-numbered copy is the 881-29me shape and rots on the next edit.
sed -n '/^    _cg_rc=0$/,/^    esac$/p' \
    "$WRAPPER" > "$W/case.sh"
if [ ! -s "$W/case.sh" ] || ! grep -q 'esac' "$W/case.sh"; then
    bad "could not extract the consumer case block from the wrapper — this fixture would have asserted nothing"
    echo "FAIL: competing-gate consumer 0/1 (1150-q462)"; exit 1
fi
ok "the consumer case block is extractable from the shipped wrapper"

drive() { # drive <exit-code> <stub-stdout>  -> prints the consumer's combined output
    local code="$1" text="$2" d="$W/run"
    rm -rf "$d"; mkdir -p "$d"
    cat > "$d/check-no-competing-gate.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "$text"
exit $code
STUB
    chmod +x "$d/check-no-competing-gate.sh"
    ( _tb_self_dir="$d"; set +e; . "$W/case.sh" ) 2>&1
}
drive_strict() { # like drive, but under the wrapper's OWN regime (set -e), IN A SEPARATE PROCESS, with a sentinel after the block
    # THE CONSTRUCTION MATTERS (2026-09-14, macbookair's build.sh death one day
    # after 1175-wuwr): bash IGNORES errexit inside a `( set -e; … )` subshell
    # that sits in $(…) or a pipeline, so the first version of this helper let
    # the pre-fix capture form print the sentinel too and could not see the
    # death it existed to pin. A driver file run by a separate bash with
    # `set -euo pipefail` at its top dies at the assignment exactly as the
    # wrapper does; its output is read back from a file, never through a pipe.
    local code="$1" text="$2" d="$W/run-strict"
    rm -rf "$d"; mkdir -p "$d"
    cat > "$d/check-no-competing-gate.sh" <<STUB
printf '%s\n' "$text"
exit $code
STUB
    chmod +x "$d/check-no-competing-gate.sh"
    {
        printf 'set -euo pipefail\n_tb_self_dir=%q\n' "$d"
        printf '. %q\necho "consumer-block-completed"\n' "$W/case.sh"
    } > "$d/driver.sh"
    bash "$d/driver.sh" > "$d/out.txt" 2>&1
    local rc=$?
    cat "$d/out.txt"
    return "$rc"
}

# 1. 0 — answered, no competitor. Quiet-ish, and must not claim anything else.
out="$(drive 0 'ok:no-competing-gate')"
case "$out" in
    *ok:no-competing-gate*) ok "0 reports the clean answer" ;;
    *)                      bad "0 produced: $out" ;;
esac

# 2. 1 — a competitor. Must SAY the run may be raced.
out="$(drive 1 'competing-gate: a build.sh is running in this checkout')"
case "$out" in
    *"may be raced"*) ok "1 warns the run may be raced" ;;
    *)                bad "1 did not warn: $out" ;;
esac
# THE REGIME ARMS (2026-09-13). The wrapper runs under `set -euo pipefail`;
# every arm above drives the block under `set +e` and so could not see that a
# bare `_cg_out="$(detector)"` EXITS the wrapper when the detector returns 1 —
# which it does whenever a gate is running in the checkout. Measured in the
# v56.9.13.1 cut: the toolbox property fixture red inside --ci-full only,
# after "Initialization complete." and before the dispatch, rc 1, no case
# message. Under the wrapper's own regime the block must COMPLETE and warn.
out="$(drive_strict 1 'competing-gate: a build.sh is running in this checkout')"
case "$out" in
    *"consumer-block-completed"*) ok "1 under set -e: the block completes (the capture survives errexit)" ;;
    *) bad "1 under set -e: the wrapper EXITED at the capture — the four-code case never ran: $out" ;;
esac
case "$out" in
    *"may be raced"*) ok "1 under set -e still warns the run may be raced" ;;
    *)                bad "1 under set -e did not warn: $out" ;;
esac
out="$(drive_strict 0 'ok:no-competing-gate')"
case "$out" in
    *"consumer-block-completed"*) ok "0 under set -e: the block completes" ;;
    *) bad "0 under set -e: the block did not complete: $out" ;;
esac

# THE OTHER NONZERO CODES, under the same regime (yoga, 2026-09-14). errexit does
# not single out 1: a bare `_cg_out="$(detector)"` exits the wrapper on EVERY
# nonzero status, so 2, 3 and an unrecognised code died there too. The arms for
# them above run under `set +e` and therefore still assert about a shell the
# wrapper does not use — the same gap as before, one code narrower, and the
# reason this refines rather than repeats the two arms above.
#
# It is the `|| _cg_rc=$?` form that makes them all survive, and that form is
# uniform across codes; these arms are what stops a later edit from restoring
# the bare assignment and leaving 1 and 0 green while 2, 3 and 9 die silently.
for _sc in 2 3 9; do
    out="$(drive_strict "$_sc" 'stub output for the strict regime')"
    case "$out" in
        *"consumer-block-completed"*)
            ok "$_sc under set -e: the block completes (errexit survives every nonzero code, not only 1)" ;;
        *)
            bad "$_sc under set -e: the wrapper EXITED at the capture — the case never ran: $out" ;;
    esac
done

# 3. 2 — caller contract. Must name THIS CALL SITE as wrong, not the host.
out="$(drive 2 'refused:competing-gate:caller-contract (...)')"
case "$out" in
    *caller-contract*|*"call site"*) ok "2 names the call site as the thing to fix" ;;
    *)                               bad "2 did not name the call site: $out" ;;
esac

# 4. 3 — could-not-run. Must say it is NOT a clean verdict (965-sxec).
out="$(drive 3 'could-not-run:competing-gate:blind (...)')"
case "$out" in
    *"NOT a clean-room verdict"*|*"could not be asked"*) ok "3 says it is not a clean verdict" ;;
    *)                                                   bad "3 read as clean: $out" ;;
esac

# 5. THE NEGATIVE CONTROL. 2 and 3 must produce DIFFERENT observable responses.
#    A consumer that logs both and proceeds passes arms 1-4 and fails only here.
o2="$(drive 2 'X')"; o3="$(drive 3 'X')"
if [ "$o2" = "$o3" ]; then
    bad "2 and 3 produced IDENTICAL output — a wiring bug is indistinguishable from an unsupported substrate, which is the collapse this row exists to prevent"
else
    ok "2 and 3 produce different responses"
fi

# 6. NO DEFAULT THAT PROCEEDS. An unrecognised code must be said aloud, not
#    swallowed — a grammar change nobody taught this caller.
out="$(drive 9 'something new')"
case "$out" in
    *unrecognised*) ok "an unknown code is reported, not swallowed" ;;
    *)              bad "code 9 fell through silently: $out" ;;
esac

# 7. NONE OF THEM STOPS THE BUILD. The detector is advisory until 1141-vf9w's
#    promotion, and the first reader of these codes must not be the first thing
#    that can stop a gate.
_stopped=""
for c in 0 1 2 3 9; do
    ( _tb_self_dir="$W/run"; set +e; drive "$c" 'x' >/dev/null 2>&1 ) || true
    out="$(drive "$c" 'x' 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && _stopped="$_stopped $c"
done
if [ -z "$_stopped" ]; then ok "no verdict stops the build — the consumer stays advisory"
else bad "these codes made the consumer exit non-zero:$_stopped — promotion is a separate change"; fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "PASS: competing-gate consumer $pass/$total (1150-q462)"; exit 0; fi
echo "FAIL: competing-gate consumer $pass/$total (1150-q462)"; exit 1
