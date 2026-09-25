#!/usr/bin/env bash
# test-plan-binary-remedy-names-only-a-runnable-binary.sh — ORDER 1267-uafx.
#
# The pre-push plan-only lane, on refusing a STALE plan binary, looks for a
# FRESHER build of the same binary and prints it as the remedy:
#   REMEDY: TILLANDSIAS_PLAN_BIN=<candidate> git push ...
# It chose that candidate by MTIME ALONE. On a shared Windows/WSL checkout the
# WSL gate leaves a Linux ELF beside the .exe, newer than it, which exits 126
# on the Windows side — and the hook recommended it verbatim (measured on
# yolanda 2026-09-19). 704-zcgi's rule: an executable bit is a claim; RUNNING
# the binary is evidence.
#
# Drives the REAL hook against a scratch checkout, the same harness as
# test-plan-binary-freshness.sh. The unrunnable candidate is BUILT HERE — four
# bytes of ELF magic, +x — so every arm runs on every host: bash reports it as
# "cannot execute binary file" (126) on Linux and macOS, and MINGW never
# treats a file without a shebang or MZ header as executable. A Linux host has
# no real .exe to contrast with and would otherwise skip.
#
#   ARM 1  NEGATIVE: only a newer UNRUNNABLE candidate → the remedy must NOT
#          name it, and the lane falls back to the rebuild remedy.
#   ARM 2  POSITIVE: a newer RUNNABLE candidate → it IS named, so the fix
#          cannot be "never recommend anything".
#   ARM 3  THE WINDOWS SHAPE: a newer unrunnable ELF AND a newer runnable .exe
#          → the .exe is named and the ELF is not.
# Every arm first asserts the lane REFUSED as stale, so a fixture setup that
# stops reaching the remedy block reds rather than passing vacuously.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# target_binary_runs: the same runnability rule the hook now applies (721-nyev:
# plan-binary resolution goes through the shared probe).
. "$ROOT/scripts/plan-binary-probe.sh"

pass=0; fail=0
ck() { # ck <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else
        printf '  FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}

LW="$(mktemp -d "${TMPDIR:-/tmp}/plan-remedy-runnable.XXXXXX")"
trap 'rm -rf "$LW"' EXIT
LG() { git -C "$LW/wc" -c user.email=t@t -c user.name=t "$@"; }
git init -q --bare "$LW/bare.git"
git init -q -b linux-next "$LW/wc"
( cd "$LW/wc" && git remote add origin "$LW/bare.git" && git config core.hooksPath .git/hooks )
mkdir -p "$LW/wc/scripts/hooks" "$LW/wc/plan/index.d" "$LW/wc/crates/tillandsias-plan/src" \
         "$LW/wc/target/release" "$LW/wc/target/debug"
cp "$ROOT/scripts/hooks/pre-push-local-gate.sh" "$LW/wc/scripts/hooks/"
for f in plan-binary-probe.sh gate-stamp.sh common.sh check-fragment-status-loss.sh check-issue-citation-convention.sh; do
    cp "$ROOT/scripts/$f" "$LW/wc/scripts/" 2>/dev/null || true
done
# The hook sources the probe; without it the lane cannot resolve a binary and
# every arm below would measure the wrong refusal.
[ -f "$LW/wc/scripts/plan-binary-probe.sh" ] || { echo "fail:plan-remedy-runnable:setup:probe-not-copied"; exit 1; }
chmod +x "$LW/wc/scripts"/*.sh "$LW/wc/scripts/hooks"/*.sh 2>/dev/null
printf 'packets: []\n' > "$LW/wc/plan/index.yaml"
echo 'fn main() {}' > "$LW/wc/crates/tillandsias-plan/src/main.rs"
echo '# lock' > "$LW/wc/Cargo.lock"

_runnable_stub() { # $1 = path
    cat > "$1" <<'LSTUB'
#!/usr/bin/env bash
case "${1:-}" in
    capabilities) echo compact; exit 0 ;;
    check) exit 0 ;;
    validate-yaml) exit 0 ;;
    yaml-type) echo '!!map'; exit 0 ;;
esac
exit 0
LSTUB
    chmod +x "$1"
}
_unrunnable_elf() { # $1 = path — ELF magic and nothing else
    printf '\177ELF\002\001\001\000' > "$1"
    chmod +x "$1"
}

_runnable_stub "$LW/wc/target/release/tillandsias-plan"
LG add -A >/dev/null 2>&1; LG commit -q -m base
( cd "$LW/wc" && git push -q -u origin linux-next 2>/dev/null )
printf 'packets: []\n' > "$LW/wc/plan/index.d/20260923t000000z-remedy-arm.yaml"
LG add -A >/dev/null 2>&1; LG commit -q -m "a fragment push"

_lane_push() { ( cd "$LW/wc" && env -u TILLANDSIAS_PLAN_BIN -u CARGO_TARGET_DIR \
    bash scripts/hooks/pre-push-local-gate.sh origin "$LW/bare.git" 2>&1 <<< \
    "refs/heads/linux-next $(git -C "$LW/wc" rev-parse HEAD) refs/heads/linux-next $(git -C "$LW/wc" rev-parse origin/linux-next)" ); }

# The resolved binary (release, runnable) is stale against the sources; every
# candidate planted per arm is NEWER than it.
_reset_arm() {
    rm -f "$LW/wc/target/debug/tillandsias-plan" "$LW/wc/target/debug/tillandsias-plan.exe" \
          "$LW/wc/target/release/tillandsias-plan.exe"
    touch -t 202609041215 "$LW/wc/target/release/tillandsias-plan"
    touch -t 202609111933 "$LW/wc/crates/tillandsias-plan/src/main.rs" "$LW/wc/Cargo.lock"
}
_newer() { touch -t 202609221200 "$@"; }
_has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# The unrunnable candidate must really be unrunnable HERE, or arm 1 proves
# nothing on this host (a sabotage must assert its own premise).
_unrunnable_elf "$LW/elf-probe"
"$LW/elf-probe" --help >/dev/null 2>&1; _prc=$?
case "$_prc" in
    126|127) ck "premise: the planted ELF does not run on this host (rc $_prc)" yes yes ;;
    *)       ck "premise: the planted ELF does not run on this host (rc $_prc)" yes no ;;
esac

# ── ARM 1 — NEGATIVE ────────────────────────────────────────────────────────
_reset_arm
_unrunnable_elf "$LW/wc/target/debug/tillandsias-plan"; _newer "$LW/wc/target/debug/tillandsias-plan"
_out="$(_lane_push)"; _rc=$?
ck "arm1: the lane refuses the stale binary" 1 "$_rc"
ck "arm1: the refusal names STALENESS" yes "$(_has "$_out" "is STALE")"
ck "arm1: the unrunnable newer ELF is NOT named as a remedy" no \
   "$(_has "$_out" "TILLANDSIAS_PLAN_BIN=./target/debug/tillandsias-plan ")"
ck "arm1: no FRESHER line at all" no "$(_has "$_out" "A FRESHER build")"
ck "arm1: falls back to the rebuild remedy" yes "$(_has "$_out" "cargo build --release -p tillandsias-plan")"

# ── ARM 2 — POSITIVE ────────────────────────────────────────────────────────
_reset_arm
_runnable_stub "$LW/wc/target/debug/tillandsias-plan.exe"; _newer "$LW/wc/target/debug/tillandsias-plan.exe"
_out="$(_lane_push)"; _rc=$?
ck "arm2: the lane refuses the stale binary" 1 "$_rc"
# Assert on what the remedy DOES, not on its spelling. On MINGW `-f
# ./target/debug/tillandsias-plan` is true when only the .exe exists (MSYS
# appends the suffix), so the hook names the extensionless path there, and it
# resolves to the same runnable .exe in Git Bash. Measured on yolanda: the
# spelling-pinned version of this arm failed while the remedy was correct.
_named="$(printf '%s\n' "$_out" | sed -n 's|.*REMEDY: TILLANDSIAS_PLAN_BIN=\([^ ]*\) git push.*|\1|p' | awk 'NR == 1')"
case "$_named" in
    ./target/debug/tillandsias-plan|./target/debug/tillandsias-plan.exe)
        ck "arm2: a newer candidate IS named ($_named)" yes yes ;;
    *)  ck "arm2: a newer candidate IS named (${_named:-none})" yes no ;;
esac
( cd "$LW/wc" && [ -n "$_named" ] && target_binary_runs "$_named" ); _nrc=$?
ck "arm2: the named remedy binary RUNS" 0 "$_nrc"

# ── ARM 3 — THE WINDOWS SHAPE ───────────────────────────────────────────────
_reset_arm
_unrunnable_elf "$LW/wc/target/debug/tillandsias-plan"
_runnable_stub "$LW/wc/target/debug/tillandsias-plan.exe"
_newer "$LW/wc/target/debug/tillandsias-plan" "$LW/wc/target/debug/tillandsias-plan.exe"
_out="$(_lane_push)"; _rc=$?
ck "arm3: the lane refuses the stale binary" 1 "$_rc"
ck "arm3: the runnable .exe is named" yes \
   "$(_has "$_out" "TILLANDSIAS_PLAN_BIN=./target/debug/tillandsias-plan.exe git push")"
ck "arm3: the unrunnable ELF beside it is NOT named" no \
   "$(_has "$_out" "TILLANDSIAS_PLAN_BIN=./target/debug/tillandsias-plan git push")"

printf 'plan-binary-remedy-runnable: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
    echo "ok:plan-binary-remedy-runnable:$pass"
    exit 0
fi
echo "fail:plan-binary-remedy-runnable"
exit 1
