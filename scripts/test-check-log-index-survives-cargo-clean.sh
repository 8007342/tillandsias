#!/usr/bin/env bash
# @trace spec:ci-release, spec:meta-orchestration
# @trace order:888-vgs8
#
# Fixture for scripts/convergence-log-path.sh (order 888-vgs8): the convergence
# check log — the failure history skills/meta-orchestration/SKILL.md orders a
# reader to open FIRST — survives the build-cache sweep the same skill orders,
# because it no longer lives in target/.
#
# REGIME: hermetic, offline. Every arm builds its own tree and resolves through
# a COPY of the resolver placed in that tree, so nothing here depends on, or
# writes into, this checkout's .cache/ or target/. The one host-dependent arm
# (a real `cargo clean`) skips by name where cargo is not on PATH; the
# `rm -rf target` arm asserts the same property on every host, because that
# removal is what `cargo clean` does to target/ (measured for
# scripts/metrics-log-path.sh, 2026-08-26).
#
# SHELL, NOT LUA (check-shell-ratchet.lua prefers a Lua fixture): every arm
# runs a process — the resolver, the reader, cargo — and scripts/lua cannot
# spawn while 1384-aixy is blocked. Port it when it can.
#
#   1  the default resolves OUTSIDE target/, under <root>/.cache/convergence/
#   2  TILLANDSIAS_CHECK_LOG_INDEX wins verbatim and adopts nothing into it
#   3  legacy history is adopted ONCE: copied, not moved; a legacy file that
#      keeps growing is not merged a second time
#   4  PREMISE THEN PROPERTY: removing target/ deletes the legacy location
#      (the pre-fix home is gone — the control that the removal happened) and
#      the resolved index is intact
#   5  the same under a REAL `cargo clean` on a scratch crate, with
#      CARGO_TARGET_DIR pinned to the scratch tree (named skip without cargo)
#   6  the freshness reader, copied into a tree whose only history is legacy,
#      answers ok BEFORE the sweep (adoption) and STILL answers ok AFTER
#      target/ is gone — the pre-fix reader answered never: there
#   7  STATIC wiring: the two writers and the reader in THIS checkout resolve
#      through the resolver, and none keeps a target/ default outside a comment
#
#   PASS: check-log-index-survives-cargo-clean <n>/<n> skipped=<k> (888-vgs8)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$ROOT/scripts/convergence-log-path.sh"
READER="$ROOT/scripts/check-release-tier-freshness.sh"
pass=0; fail=0; skipped=0
ok()   { pass=$((pass + 1)); echo "ok:   $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && echo "      $2"; }
skip() { skipped=$((skipped + 1)); echo "skip: $1"; }

[ -x "$RESOLVER" ] || { echo "FAIL: $RESOLVER is not executable"; echo "FAIL: check-log-index-survives-cargo-clean 0/1 (888-vgs8)"; exit 1; }

# Scratch under the checkout when the helper exists (1637-cnxq), else the
# portable default; either way one tree, removed on exit.
SCRATCH_ROOT="$("$ROOT/scripts/scratch-dir.sh" fixtures 2>/dev/null)" || SCRATCH_ROOT="${TMPDIR:-/tmp}"
W="$(mktemp -d "$SCRATCH_ROOT/check-log-index.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$W"' EXIT INT TERM

# A tree with the resolver (and the reader) in place, and a legacy index.
mktree() { # mktree <dir>
    mkdir -p "$1/scripts" "$1/target/convergence"
    cp "$RESOLVER" "$1/scripts/convergence-log-path.sh"
    cp "$READER" "$1/scripts/check-release-tier-freshness.sh"
}
rec() { # rec <run_id> <check_id> <status> -> one FULL-tier record, the writer's shape
    printf '{"ci_run_id":"%s","ci_phase":"all","check_id":"%s","status":"%s","source_log":"","archived_log":"a","sha256":"x","duration_ms":1}\n' "$1" "$2" "$3"
}
resolve() { # resolve <dir> -> stdout path; stderr to $W/err
    (cd "$1" && env -u TILLANDSIAS_CHECK_LOG_INDEX bash scripts/convergence-log-path.sh 2>"$W/err")
}
lines() { # record count of a file, or `absent`; arithmetic strips wc's padding (no pipe: shell ratchet)
    if [ -f "$1" ]; then local n; n="$(wc -l < "$1")"; echo $((n + 0)); else echo absent; fi
}

RUN_ID="local-ci-$(date -u +%Y%m%dT%H%M%SZ)"

# ARM 1
T="$W/t1"; mktree "$T"
p="$(resolve "$T")"
case "$p" in
    "$T/.cache/convergence/check-logs.jsonl") ok "ARM 1: the default resolves to <root>/.cache/convergence/check-logs.jsonl, outside target/" ;;
    */target/*) bad "ARM 1: the default still lives inside target/" "$p" ;;
    *) bad "ARM 1: unexpected default" "$p" ;;
esac

# ARM 2
T="$W/t2"; mktree "$T"
rec "$RUN_ID" a pass > "$T/target/convergence/check-logs.jsonl"
p="$(cd "$T" && TILLANDSIAS_CHECK_LOG_INDEX="$W/own.jsonl" bash scripts/convergence-log-path.sh 2>"$W/err")"
if [ "$p" = "$W/own.jsonl" ] && [ ! -e "$T/.cache/convergence/check-logs.jsonl" ] && [ ! -e "$W/own.jsonl" ]; then
    ok "ARM 2: TILLANDSIAS_CHECK_LOG_INDEX wins verbatim, and nothing is adopted into it or beside it"
else
    bad "ARM 2: the override was second-guessed" "p=$p new=$(lines "$T/.cache/convergence/check-logs.jsonl") own=$(lines "$W/own.jsonl")"
fi

# ARM 3
T="$W/t3"; mktree "$T"
{ rec "$RUN_ID" a pass; rec "$RUN_ID" b pass; rec "$RUN_ID" c pass; } > "$T/target/convergence/check-logs.jsonl"
p="$(resolve "$T")"
note1="$(cat "$W/err")"
n_new="$(lines "$T/.cache/convergence/check-logs.jsonl")"; n_old="$(lines "$T/target/convergence/check-logs.jsonl")"
rec "$RUN_ID" d pass >> "$T/target/convergence/check-logs.jsonl"
p2="$(resolve "$T")"
note2="$(cat "$W/err")"
n_new2="$(lines "$T/.cache/convergence/check-logs.jsonl")"
if [ "$n_new" = 3 ] && [ "$n_old" = 3 ] && [ "$note1" = "note:check-log-index:adopted-legacy:3" ] \
    && [ "$n_new2" = 3 ] && [ -z "$note2" ] && [ "$p" = "$p2" ]; then
    ok "ARM 3: legacy history is adopted once — copied (3 -> 3, legacy intact, note on stderr), and a legacy file that grew to 4 is not merged again"
else
    bad "ARM 3: adoption is not copy-once" "new=$n_new old=$n_old note1='$note1' new2=$n_new2 note2='$note2'"
fi

# ARM 4
T="$W/t4"; mktree "$T"
{ rec "$RUN_ID" a pass; rec "$RUN_ID" b pass; } > "$T/target/convergence/check-logs.jsonl"
p="$(resolve "$T")"
rm -rf "$T/target"
if [ -e "$T/target/convergence/check-logs.jsonl" ]; then
    bad "ARM 4: PREMISE FAILED — target/ was not removed, so nothing below is evidence"
elif [ "$(lines "$p")" = 2 ]; then
    ok "ARM 4: with target/ removed (what cargo clean does), the legacy location is gone and the resolved index still holds its 2 records"
else
    bad "ARM 4: the resolved index did not survive the removal of target/" "p=$p lines=$(lines "$p")"
fi

# ARM 5 — a REAL cargo clean. CARGO_TARGET_DIR is pinned to the scratch tree
# on purpose: in a forge it is exported and points at the REAL build cache
# (721-nyev), and a bare `cargo clean` here would empty that.
if command -v cargo >/dev/null 2>&1; then
    T="$W/t5"; mktree "$T"
    mkdir -p "$T/src"
    printf '[package]\nname = "scratch"\nversion = "0.0.0"\nedition = "2021"\n\n[dependencies]\n' > "$T/Cargo.toml"
    : > "$T/src/lib.rs"
    { rec "$RUN_ID" a pass; rec "$RUN_ID" b pass; } > "$T/target/convergence/check-logs.jsonl"
    p="$(resolve "$T")"
    (cd "$T" && CARGO_TARGET_DIR="$T/target" cargo clean -q --offline >"$W/cargo.out" 2>&1); crc=$?
    if [ "$crc" -ne 0 ]; then
        bad "ARM 5: cargo clean itself failed in the scratch crate" "rc=$crc $(head -3 "$W/cargo.out" | tr '\n' '|')"
    elif [ -e "$T/target/convergence/check-logs.jsonl" ]; then
        bad "ARM 5: PREMISE FAILED — cargo clean left target/convergence/check-logs.jsonl in place"
    elif [ "$(lines "$p")" = 2 ]; then
        ok "ARM 5: a real cargo clean removed the legacy location and the resolved index still holds its 2 records"
    else
        bad "ARM 5: the resolved index did not survive a real cargo clean" "p=$p lines=$(lines "$p")"
    fi
else
    skip "ARM 5: no cargo on PATH — the real cargo clean arm did not run here (ARM 4 covers the property)"
fi

# ARM 6 — the reader. Legacy history only, no new index: the reader must find
# the full-tier run through adoption, and must STILL find it once target/ is
# gone. The pre-fix reader read target/ directly and answered never: after a
# sweep — a wrong answer about the record this row protects.
T="$W/t6"; mktree "$T"
{ rec "$RUN_ID" spec-cheatsheet-binding pass; rec "$RUN_ID" expert-groundtruth-harness pass; } > "$T/target/convergence/check-logs.jsonl"
out_before="$(cd "$T" && env -u TILLANDSIAS_CHECK_LOG_INDEX bash scripts/check-release-tier-freshness.sh 2>&1)"; rc_before=$?
rm -rf "$T/target"
out_after="$(cd "$T" && env -u TILLANDSIAS_CHECK_LOG_INDEX bash scripts/check-release-tier-freshness.sh 2>&1)"; rc_after=$?
case "$out_before" in *"ok:release-tier-fresh:$RUN_ID:"*) fb=1 ;; *) fb=0 ;; esac
case "$out_after"  in *"ok:release-tier-fresh:$RUN_ID:"*) fa=1 ;; *) fa=0 ;; esac
if [ -e "$T/target" ]; then
    bad "ARM 6: PREMISE FAILED — target/ was not removed"
elif [ "$rc_before" = 0 ] && [ "$fb" = 1 ] && [ "$rc_after" = 0 ] && [ "$fa" = 1 ]; then
    ok "ARM 6: the freshness reader answers ok from adopted legacy history, and still answers ok after target/ is gone"
else
    bad "ARM 6: the reader lost the release-tier answer across the sweep" "before rc=$rc_before fresh=$fb; after rc=$rc_after fresh=$fa; after=$(printf '%s' "$out_after" | head -1)"
fi

# ARM 7 — static wiring in THIS checkout.
missing=""; leftover=""
for f in scripts/local-ci.sh scripts/record-ci-phase-result.sh scripts/check-release-tier-freshness.sh; do
    c="$(grep -v '^[[:space:]]*#' "$ROOT/$f" | grep -c 'convergence-log-path.sh')"
    [ "$c" -ge 1 ] || missing="$missing $f"
    l="$(grep -v '^[[:space:]]*#' "$ROOT/$f" | grep -c 'target/convergence/check-logs.jsonl')"
    [ "$l" -eq 0 ] || leftover="$leftover $f"
done
if [ -z "$missing" ] && [ -z "$leftover" ]; then
    ok "ARM 7: local-ci.sh, record-ci-phase-result.sh and check-release-tier-freshness.sh resolve through the resolver and keep no target/ default outside comments"
else
    bad "ARM 7: wiring incomplete" "not-resolving:[$missing] target-default-left:[$leftover]"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: check-log-index-survives-cargo-clean $pass/$total skipped=$skipped (888-vgs8)"
    exit 0
fi
echo "FAIL: check-log-index-survives-cargo-clean $pass/$total skipped=$skipped (888-vgs8)"
exit 1
