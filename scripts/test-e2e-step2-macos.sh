#!/bin/bash
# Hermetic fixture for scripts/e2e-step2-macos.sh (1181-bkem).
#
# Runs on any host: HOME is redirected to a scratch dir per arm, so no real
# tray, no real Application Support/Caches state, no podman is ever touched.
#
# Arms:
#   1. TILLANDSIAS_RESET_KEEP_MODELS=1 spares models/ byte-identical, wipes
#      everything else (VM dir, other cache files).
#   2. Flag unset wipes everything, unchanged behavior.
#   3. Mutation control: a copy of the script with the sparing construct
#      stripped (the find/! -name models branch replaced by an unconditional
#      rm -rf "$CACHE_DIR") reds arm 1's property under the same flag — cmp
#      proves the mutant differs from the original.
#   4. Residue negative: a copy of the script with the unconditional
#      rm -rf "$CACHE_DIR" (flag-unset branch) removed leaves CACHE_DIR
#      behind, so the residue assertion must fire FAIL: residue and name it.
#
# Final line: 'PASS: test-e2e-step2-macos N/N (1181-bkem)' or
# 'FAIL: test-e2e-step2-macos N/N (1181-bkem)'.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$SCRIPT_DIR/e2e-step2-macos.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/e2e-step2-macos-fixture.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

total=5
arm_fails=0
NAME="test-e2e-step2-macos"

fail() {
  echo "FAIL: $1" >&2
}

# seed_home <dir> — populates a fresh fake $HOME with a VM dir and a cache
# dir carrying models/weights.bin, a non-model file, and a subdirectory.
seed_home() {
  home="$1"
  mkdir -p "$home/Library/Application Support/tillandsias"
  head -c 1024 /dev/urandom > "$home/Library/Application Support/tillandsias/rootfs.img"
  mkdir -p "$home/Library/Caches/tillandsias/models" "$home/Library/Caches/tillandsias/sub"
  head -c 2048 /dev/urandom > "$home/Library/Caches/tillandsias/models/weights.bin"
  head -c 64 /dev/urandom > "$home/Library/Caches/tillandsias/other.bin"
  head -c 16 /dev/urandom > "$home/Library/Caches/tillandsias/sub/x"
}

# ---------------------------------------------------------------------
# Arm 1: flag set — models/ survives byte-identical, everything else gone.
# ---------------------------------------------------------------------
HOME1="$TMPROOT/home1"
LOG1="$TMPROOT/log1"
mkdir -p "$HOME1" "$LOG1"
seed_home "$HOME1"
SHA_BEFORE="$(sha256sum "$HOME1/Library/Caches/tillandsias/models/weights.bin" | cut -d' ' -f1)"

OUT1="$(HOME="$HOME1" TILLANDSIAS_RESET_KEEP_MODELS=1 bash "$SUT" "$LOG1" 2>&1)"
RC1=$?

arm1_ok=1
[ "$RC1" -eq 0 ] || { fail "arm1: exit $RC1, want 0 — output: $OUT1"; arm1_ok=0; }
[ -e "$HOME1/Library/Application Support/tillandsias" ] && { fail "arm1: VM_DIR survived"; arm1_ok=0; }
if [ -f "$HOME1/Library/Caches/tillandsias/models/weights.bin" ]; then
  SHA_AFTER="$(sha256sum "$HOME1/Library/Caches/tillandsias/models/weights.bin" | cut -d' ' -f1)"
  [ "$SHA_AFTER" = "$SHA_BEFORE" ] || { fail "arm1: weights.bin changed ($SHA_BEFORE -> $SHA_AFTER)"; arm1_ok=0; }
else
  fail "arm1: models/weights.bin missing"
  arm1_ok=0
fi
[ -e "$HOME1/Library/Caches/tillandsias/other.bin" ] && { fail "arm1: other.bin survived"; arm1_ok=0; }
[ -e "$HOME1/Library/Caches/tillandsias/sub" ] && { fail "arm1: sub/ survived"; arm1_ok=0; }
case "$OUT1" in
  *"keep-models: spared $HOME1/Library/Caches/tillandsias/models"*) ;;
  *) fail "arm1: stdout missing keep-models line naming the path — got: $OUT1"; arm1_ok=0 ;;
esac
case "$OUT1" in
  *"ok:e2e-step2-macos:destroyed:kept-models"*) ;;
  *) fail "arm1: stdout missing kept-models verdict — got: $OUT1"; arm1_ok=0 ;;
esac
RESIDUE1="$(cat "$LOG1/02-macos-residue.txt" 2>/dev/null)"
OFFENDING1="$(printf '%s\n' "$RESIDUE1" | tail -n +2)"
[ -z "$OFFENDING1" ] || { fail "arm1: residue file names offending paths — got: $RESIDUE1"; arm1_ok=0; }
if [ "$arm1_ok" -eq 1 ]; then
  echo "ok: arm1 (flag set spares models byte-identical)"
else
  arm_fails=$((arm_fails + 1))
fi

# ---------------------------------------------------------------------
# Arm 2: flag unset — everything gone, unchanged behavior.
# ---------------------------------------------------------------------
HOME2="$TMPROOT/home2"
LOG2="$TMPROOT/log2"
mkdir -p "$HOME2" "$LOG2"
seed_home "$HOME2"

OUT2="$(HOME="$HOME2" bash "$SUT" "$LOG2" 2>&1)"
RC2=$?

arm2_ok=1
[ "$RC2" -eq 0 ] || { fail "arm2: exit $RC2, want 0 — output: $OUT2"; arm2_ok=0; }
[ -e "$HOME2/Library/Application Support/tillandsias" ] && { fail "arm2: VM_DIR survived"; arm2_ok=0; }
[ -e "$HOME2/Library/Caches/tillandsias" ] && { fail "arm2: CACHE_DIR survived"; arm2_ok=0; }
case "$OUT2" in
  *"ok:e2e-step2-macos:destroyed"*)
    case "$OUT2" in
      *"kept-models"*) fail "arm2: verdict wrongly claims kept-models — got: $OUT2"; arm2_ok=0 ;;
    esac
    ;;
  *) fail "arm2: stdout missing destroyed verdict — got: $OUT2"; arm2_ok=0 ;;
esac
if [ "$arm2_ok" -eq 1 ]; then
  echo "ok: arm2 (flag unset destroys everything)"
else
  arm_fails=$((arm_fails + 1))
fi

# ---------------------------------------------------------------------
# Arm 3: mutation control — sparing construct stripped FROM CONTENT.
# ---------------------------------------------------------------------
MUTANT1="$TMPROOT/e2e-step2-macos.mutant-strip-spare.sh"
awk '
  /-maxdepth 1 ! -name models -exec rm -rf/ { print "    rm -rf \"$CACHE_DIR\""; next }
  { print }
' "$SUT" > "$MUTANT1"
chmod +x "$MUTANT1"

arm3_ok=1
if cmp -s "$SUT" "$MUTANT1"; then
  fail "arm3: mutant1 is byte-identical to the original — strip did not apply"
  arm3_ok=0
else
  echo "ok: arm3 mutant1 differs from original (cmp)"
fi
# A no-op strip control: awk with no matching pattern must reproduce the
# original exactly, proving the awk substitution above is not a fixed
# rewrite that would "differ" regardless of what it targets.
NOOP_STRIP="$TMPROOT/e2e-step2-macos.noop-strip.sh"
awk '
  /this-pattern-matches-nothing-in-the-real-script/ { next }
  { print }
' "$SUT" > "$NOOP_STRIP"
if cmp -s "$SUT" "$NOOP_STRIP"; then
  echo "ok: arm3 no-op strip reproduces the original exactly (cmp)"
else
  fail "arm3: no-op strip control unexpectedly differs from the original"
  arm3_ok=0
fi

HOME3="$TMPROOT/home3"
LOG3="$TMPROOT/log3"
mkdir -p "$HOME3" "$LOG3"
seed_home "$HOME3"
OUT3="$(HOME="$HOME3" TILLANDSIAS_RESET_KEEP_MODELS=1 bash "$MUTANT1" "$LOG3" 2>&1)"
if [ -e "$HOME3/Library/Caches/tillandsias/models/weights.bin" ]; then
  fail "arm3: mutant spared models — arm1's property does not red on the mutant. output: $OUT3"
  arm3_ok=0
else
  echo "ok: arm3 mutant reds arm1's survival property (models gone under the flag)"
fi
[ "$arm3_ok" -eq 1 ] || arm_fails=$((arm_fails + 1))

# ---------------------------------------------------------------------
# Arm 4: residue negative — one rm removed FROM CONTENT leaves CACHE_DIR
# behind under a flag-unset run, so the residue assertion must fire.
# ---------------------------------------------------------------------
MUTANT2="$TMPROOT/e2e-step2-macos.mutant-drop-cache-rm.sh"
awk '
  $0 == "  rm -rf \"$CACHE_DIR\"" { print "  :"; next }
  { print }
' "$SUT" > "$MUTANT2"
chmod +x "$MUTANT2"

arm4_ok=1
if cmp -s "$SUT" "$MUTANT2"; then
  fail "arm4: mutant2 is byte-identical to the original — drop did not apply"
  arm4_ok=0
else
  echo "ok: arm4 mutant2 differs from original (cmp)"
fi

HOME4="$TMPROOT/home4"
LOG4="$TMPROOT/log4"
mkdir -p "$HOME4" "$LOG4"
seed_home "$HOME4"
OUT4="$(HOME="$HOME4" bash "$MUTANT2" "$LOG4" 2>&1)"
RC4=$?
[ "$RC4" -eq 1 ] || { fail "arm4: exit $RC4, want 1 (residue) — output: $OUT4"; arm4_ok=0; }
case "$OUT4" in
  *"FAIL: residue"*) ;;
  *) fail "arm4: stdout missing 'FAIL: residue' — got: $OUT4"; arm4_ok=0 ;;
esac
RESIDUE4="$(cat "$LOG4/02-macos-residue.txt" 2>/dev/null)"
case "$RESIDUE4" in
  *"$HOME4/Library/Caches/tillandsias"*) ;;
  *) fail "arm4: residue file does not name the offending path — got: $RESIDUE4"; arm4_ok=0 ;;
esac
if [ "$arm4_ok" -eq 1 ]; then
  echo "ok: arm4 (residue negative fires FAIL: residue and names the path)"
else
  arm_fails=$((arm_fails + 1))
fi

# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# Arm 5: flag SET but no models/ dir — the flag has nothing to spare and must
# not leave an empty cache dir behind as residue: plain destroy, exit 0, the
# destroyed verdict without kept-models, and a line saying nothing was spared
# (the verifier's refutation of the first draft, 2026-09-14).
# ---------------------------------------------------------------------
HOME5="$TMPROOT/home5"
LOG5="$TMPROOT/log5"
mkdir -p "$HOME5" "$LOG5"
seed_home "$HOME5"
rm -rf "$HOME5/Library/Caches/tillandsias/models"

OUT5="$(HOME="$HOME5" TILLANDSIAS_RESET_KEEP_MODELS=1 bash "$SUT" "$LOG5" 2>&1)"
RC5=$?

arm5_ok=1
[ "$RC5" -eq 0 ] || { fail "arm5: exit $RC5, want 0 — output: $OUT5"; arm5_ok=0; }
[ -e "$HOME5/Library/Application Support/tillandsias" ] && { fail "arm5: VM_DIR survived"; arm5_ok=0; }
[ -e "$HOME5/Library/Caches/tillandsias" ] && { fail "arm5: an EMPTY cache dir was left as residue under the flag"; arm5_ok=0; }
case "$OUT5" in
  *"keep-models: nothing to spare"*) ;;
  *) fail "arm5: stdout does not say nothing was spared — got: $OUT5"; arm5_ok=0 ;;
esac
case "$OUT5" in
  *"ok:e2e-step2-macos:destroyed"*)
    case "$OUT5" in
      *"kept-models"*) fail "arm5: verdict wrongly claims kept-models — got: $OUT5"; arm5_ok=0 ;;
    esac
    ;;
  *) fail "arm5: stdout missing destroyed verdict — got: $OUT5"; arm5_ok=0 ;;
esac
if [ "$arm5_ok" -eq 1 ]; then
  echo "ok: arm5 (flag set with no models dir destroys everything and says nothing was spared)"
else
  arm_fails=$((arm_fails + 1))
fi

passed=$((total - arm_fails))
if [ "$arm_fails" -eq 0 ]; then
  echo "PASS: $NAME $total/$total (1181-bkem)"
  exit 0
else
  echo "FAIL: $NAME $passed/$total (1181-bkem)"
  exit 1
fi
