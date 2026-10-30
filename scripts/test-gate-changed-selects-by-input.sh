#!/usr/bin/env bash
# @trace order:1916-tsel, order:1916-gbct, spec:ci-release
#
# Fixture for `./build.sh --changed [base]` (scripts/gate-changed.sh): the
# warm-forge loop runs ONLY the cargo tests and fixtures whose inputs
# intersect the diff, and falls back to EVERYTHING when it cannot tell.
#
# Mutation-shaped: a stub tree (its own build.sh --check block, a gate step,
# two fixtures with declared inputs, a three-crate workspace where `leaf`
# depends on `base`) is mutated one path at a time and the selection read.
#   1 touching fixture A's input selects A and not B
#   2 touching B's input (unrelated to A) does not select A
#   3 a crate change selects that crate and its reverse dependents only
#   4 a path no fixture or crate declares selects everything (fail-safe)
#   5 a guard file (build.sh) selects everything
#   6 a .step file selects the fixture it wires, not everything
#   7 the real tree's population is not empty (a broken extractor is not green)
#   8 build.sh accepts --changed and dispatches to gate-changed.sh
#   9 --run RUNS what --list selects: an argless fixture executes (an empty
#     tab field once shifted the row and nothing ran), and a red selected
#     fixture fails the run
# FAILS ON THE PRE-FIX TREE: there scripts/gate-changed.sh does not exist and
# build.sh has no --changed, so every arm reports could-not-run / FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/scripts/gate-changed.sh"
fail=0
pass=0
arm() { if [ "$2" = ok ]; then pass=$((pass + 1)); echo "ok:arm-$1"; else fail=$((fail + 1)); echo "FAIL:arm-$1 — $3"; fi; }

if [ ! -f "$SUBJECT" ]; then
    echo "FAIL:gate-changed-selects-by-input:subject-missing — scripts/gate-changed.sh does not exist, so ./build.sh --changed cannot select anything"
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-changed-fx.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
T="$TMP/tree"
mkdir -p "$T/scripts/gate-steps.d" "$T/data" "$T/crates/base/src" "$T/crates/leaf/src" "$T/crates/other/src"
cp "$SUBJECT" "$T/scripts/gate-changed.sh"

cat > "$T/build.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "$FLAG_CHECK" == true ]]; then
    _step "Checking A..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-a.sh" 2>&1; then exit 1; fi
    _step "Checking B..."
    if ! _run bash "$SCRIPT_DIR/scripts/test-b.sh" 2>&1; then exit 1; fi
elif [[ "$FLAG_TEST$FLAG_CHECK" == "falsefalse" ]]; then
    :
fi
EOF
cat > "$T/scripts/test-a.sh" <<'EOF'
#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
grep -q alpha "$ROOT/data/a.txt"
EOF
cat > "$T/scripts/test-b.sh" <<'EOF'
#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
grep -q beta "$ROOT/data/b.txt"
EOF
cat > "$T/scripts/test-c.sh" <<'EOF'
#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
grep -q gamma "$ROOT/data/c.txt"
EOF
cat > "$T/scripts/gate-steps.d/010-c.step" <<'EOF'
STEP_DESC="Checking C"
STEP_SCRIPT="scripts/test-c.sh"
STEP_ERROR="c failed"
STEP_OK="c ok"
EOF
echo alpha > "$T/data/a.txt"; echo beta > "$T/data/b.txt"; echo gamma > "$T/data/c.txt"
echo notes > "$T/NOTES.unmapped"
cat > "$T/Cargo.toml" <<'EOF'
[workspace]
members = [
    "crates/base",
    "crates/leaf",
    "crates/other",
]
EOF
printf '[package]\nname = "stub-base"\n' > "$T/crates/base/Cargo.toml"
printf '[package]\nname = "stub-leaf"\n\n[dependencies]\nstub-base = { path = "../base" }\n' > "$T/crates/leaf/Cargo.toml"
printf '[package]\nname = "stub-other"\n' > "$T/crates/other/Cargo.toml"
for c in base leaf other; do echo "pub fn f() {}" > "$T/crates/$c/src/lib.rs"; done
git -C "$T" init -q 2>/dev/null || { echo "could-not-run:gate-changed-selects-by-input:no-git"; exit 1; }

sel() {  # $@ = changed paths -> selection text
    printf '%s\n' "$@" > "$TMP/changed"
    bash "$T/scripts/gate-changed.sh" --list --files "$TMP/changed" 2>&1
}
has() { grep -qF -- "$2" <<<"$1"; }

out="$(sel data/a.txt)"
if has "$out" "select:fixture:scripts/test-a.sh" && ! has "$out" "scripts/test-b.sh" && ! has "$out" "select:all"; then arm 1 ok; else arm 1 no "data/a.txt did not select exactly test-a: $out"; fi

out="$(sel data/b.txt)"
if has "$out" "select:fixture:scripts/test-b.sh" && ! has "$out" "scripts/test-a.sh"; then arm 2 ok; else arm 2 no "data/b.txt selected test-a or missed test-b: $out"; fi

out="$(sel crates/base/src/lib.rs)"
out2="$(sel crates/other/src/lib.rs)"
if has "$out" "select:crate:stub-base" && has "$out" "select:crate:stub-leaf" && ! has "$out" "stub-other" \
   && has "$out2" "select:crate:stub-other" && ! has "$out2" "stub-base" && ! has "$out2" "stub-leaf"; then arm 3 ok
else arm 3 no "reverse-dependency selection wrong: base-> [$out] other-> [$out2]"; fi

out="$(sel NOTES.unmapped)"
if has "$out" "select:all reason=unmapped:NOTES.unmapped"; then arm 4 ok; else arm 4 no "an unmapped path did not select everything: $out"; fi

out="$(sel build.sh)"
if has "$out" "select:all reason=guard:build.sh"; then arm 5 ok; else arm 5 no "build.sh did not select everything: $out"; fi

out="$(sel scripts/gate-steps.d/010-c.step)"
if has "$out" "select:fixture:scripts/test-c.sh" && ! has "$out" "select:all" && ! has "$out" "test-a.sh"; then arm 6 ok; else arm 6 no "a .step change did not select exactly its fixture: $out"; fi

# 7: the REAL tree. A path nothing declares must select all, and the line must
# carry a population the size of the gate, not zero.
printf 'no/such/path.unmapped\n' > "$TMP/real"
out="$(bash "$SUBJECT" --list --files "$TMP/real" 2>&1)"
n="$(sed -n 's/.*fixtures=[0-9]*\/\([0-9]*\).*/\1/p' <<<"$out" | head -n 1)"
if has "$out" "select:all" && [ "${n:-0}" -ge 300 ]; then arm 7 ok; else arm 7 no "real-tree population ${n:-none} < 300 or no fail-safe: $out"; fi

# 8: build.sh wires the flag to the subject.
if grep -qE '^[[:space:]]+--changed\)' "$ROOT/build.sh" && grep -qF 'scripts/gate-changed.sh" --run' "$ROOT/build.sh"; then arm 8 ok
else arm 8 no "build.sh has no --changed flag dispatching to scripts/gate-changed.sh --run"; fi

# 9: --run executes the selection. data/a.txt selects only test-a (argless).
printf 'data/a.txt\n' > "$TMP/changed"
out="$(bash "$T/scripts/gate-changed.sh" --run --files "$TMP/changed" 2>&1)"; rc=$?
echo delta > "$T/data/a.txt"
out2="$(bash "$T/scripts/gate-changed.sh" --run --files "$TMP/changed" 2>&1)"; rc2=$?
if [ "$rc" -eq 0 ] && has "$out" "ok:gate-changed:fixture:scripts/test-a.sh" && has "$out" "ok:gate-changed fixtures=1 " \
   && [ "$rc2" -eq 1 ] && has "$out2" "fail:gate-changed:fixture:scripts/test-a.sh"; then arm 9 ok
else arm 9 no "--run did not execute exactly the selection (rc=$rc [$out]) or a red fixture passed (rc=$rc2 [$out2])"; fi

if [ "$fail" -gt 0 ]; then
    echo "FAIL:gate-changed-selects-by-input:$fail-of-$((pass + fail))"
    exit 1
fi
echo "ok:gate-changed-selects-by-input:$pass"
exit 0
