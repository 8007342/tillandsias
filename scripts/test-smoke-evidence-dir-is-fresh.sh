#!/usr/bin/env bash
# test-smoke-evidence-dir-is-fresh.sh — order 1189-7yvu
#
# The smoke runbook's §0.4 used to be `mkdir -p target/smoke-e2e` and nothing
# else, so a run inherited every evidence file from every previous run. A step
# that never reaches its write leaves the PREVIOUS run's file under the exact
# name the §5 report and any out-of-band check open — a stale PASS that is
# indistinguishable from a fresh one BY NAME.
#
# MEASURED on pirria 2026-09-14: 03-init-exit.txt containing init_exit=0, dated
# 2026-09-13 01:24, was read as this run's result while this run's --init was
# still building the proxy image. Fourteen files from the 2026-09-12/13 runs
# were present at start.
#
# HERMETIC: builds its own tree under mktemp; never touches target/ or plan/.
# It pins the ARCHIVE SEMANTICS, and it also asserts the runbook still carries
# the step — a fixture that passes against a runbook which dropped the block
# would be pinning nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNBOOK="$ROOT/skills/smoke-curl-install-and-test-e2e/SKILL.md"
fails=0
step() { printf '  %-58s %s\n' "$1" "$2"; [ "$2" = PASS ] || fails=$((fails + 1)); }

echo "test-smoke-evidence-dir-is-fresh (1189-7yvu)"

# ── STEP 1: the runbook still carries the archive step ────────────────────────
# Without this the other steps test a shell snippet that lives only in here.
if grep -q 'SMOKE_EVIDENCE_DIR=target/smoke-e2e' "$RUNBOOK" \
   && grep -q '_archived-' "$RUNBOOK" \
   && grep -q '00-run-start.txt' "$RUNBOOK"; then
    step "runbook §0.4 carries the archive step" PASS
else
    step "runbook §0.4 carries the archive step" FAIL
    echo "      the runbook no longer contains SMOKE_EVIDENCE_DIR/_archived-/00-run-start.txt"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/smoke-evidence-fresh.XXXXXX")" || exit 2
trap 'rm -rf "$tmp"' EXIT
cd "$tmp" || exit 2

# The block under test, kept byte-compatible with the runbook's §0.4.
archive_and_init() {
    SMOKE_EVIDENCE_DIR=target/smoke-e2e
    SMOKE_RUN_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ -d "$SMOKE_EVIDENCE_DIR" ] && [ -n "$(ls -A "$SMOKE_EVIDENCE_DIR" 2>/dev/null)" ]; then
        SMOKE_ARCHIVE="$SMOKE_EVIDENCE_DIR/_archived-$(date -u +%Y%m%dt%H%M%Sz)-$$"
        mkdir -p "$SMOKE_ARCHIVE"
        for _e in "$SMOKE_EVIDENCE_DIR"/*; do
            case "$_e" in *"/_archived-"*) continue ;; esac
            [ -e "$_e" ] && mv "$_e" "$SMOKE_ARCHIVE"/
        done
    fi
    mkdir -p "$SMOKE_EVIDENCE_DIR"
    printf 'run_start=%s\n' "$SMOKE_RUN_START" > "$SMOKE_EVIDENCE_DIR/00-run-start.txt"
}

# ── STEP 2: the pre-fix FAILURE is real (negative control on the OLD code) ────
# If this does not reproduce, the packet's premise is wrong and every assertion
# below is decoration.
mkdir -p target/smoke-e2e
echo "init_exit=0" > target/smoke-e2e/03-init-exit.txt
mkdir -p target/smoke-e2e          # the old §0.4, verbatim
if [ -f target/smoke-e2e/03-init-exit.txt ]; then
    step "PRE-FIX reproduces: mkdir -p leaves the stale exit file" PASS
else
    step "PRE-FIX reproduces: mkdir -p leaves the stale exit file" FAIL
fi

# ── STEP 3: after the fix, an out-of-band read finds NO file ──────────────────
archive_and_init
if [ ! -e target/smoke-e2e/03-init-exit.txt ]; then
    step "out-of-band read before the step finds no file" PASS
else
    step "out-of-band read before the step finds no file" FAIL
    echo "      still present: $(cat target/smoke-e2e/03-init-exit.txt)"
fi

# ── STEP 4: NEGATIVE CONTROL — the evidence is PRESERVED, not deleted ─────────
# A fix that satisfied step 3 with `rm -rf` would pass it and destroy the
# previous run. That is why this step exists.
found="$(find target/smoke-e2e -name '03-init-exit.txt' -path '*_archived-*' | wc -l)"
if [ "$found" -eq 1 ] && grep -q 'init_exit=0' "$(find target/smoke-e2e -name '03-init-exit.txt' -path '*_archived-*' | head -1)"; then
    step "NEGATIVE CONTROL: archived copy preserved with its content" PASS
else
    step "NEGATIVE CONTROL: archived copy preserved with its content" FAIL
    echo "      expected exactly 1 archived copy carrying init_exit=0, found $found"
fi

# ── STEP 5: the run start time is recorded ────────────────────────────────────
if grep -qE '^run_start=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
        target/smoke-e2e/00-run-start.txt; then
    step "run start recorded in 00-run-start.txt" PASS
else
    step "run start recorded in 00-run-start.txt" FAIL
fi

# ── STEP 6: repeated runs archive side by side, never nest ────────────────────
# An archive step that swept its own archives would bury the older run one level
# deeper on every run until nothing could be found.
echo "init_exit=1" > target/smoke-e2e/03-init-exit.txt
sleep 1
archive_and_init
depth="$(find target/smoke-e2e -name '_archived-*' -path '*_archived-*/_archived-*' | wc -l)"
copies="$(find target/smoke-e2e -name '03-init-exit.txt' | wc -l)"
if [ "$depth" -eq 0 ] && [ "$copies" -eq 2 ]; then
    step "repeated runs archive side by side, both preserved" PASS
else
    step "repeated runs archive side by side, both preserved" FAIL
    echo "      nested archives=$depth (want 0), preserved copies=$copies (want 2)"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "ok:smoke-evidence-dir-is-fresh:6 step(s)"
    exit 0
fi
echo "fail:smoke-evidence-dir-is-fresh:$fails step(s) failed"
exit 1
