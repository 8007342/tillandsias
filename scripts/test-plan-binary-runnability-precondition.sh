#!/usr/bin/env bash
# @trace order:1058-fenk
#
# Pin: a plan binary that EXISTS but cannot RUN must make the issue-capture
# fixture skip with a named reason, never fail its precondition.
#
# THE RULE IS ALREADY WRITTEN DOWN, in scripts/plan-binary-probe.sh: "an
# executable BIT is a claim; RUNNING the binary is evidence." That file exists
# because four scripts independently wrote `[ -x target/release/tillandsias-plan ]`
# and all four broke the same way. test-pre-push-issue-capture-lane.sh wrote a
# fifth copy, and it broke a fifth way.
#
# MEASURED by pirria 2026-09-05. cycle-preflight builds the binary on the HOST;
# the gate consumes it inside the tillandsias-builder toolbox. On a
# rolling-release host whose glibc is newer than the image (CachyOS 2.44 vs
# fedora-toolbox:42) the same file runs on the host and cannot link in the
# toolbox:
#   ./target/release/tillandsias-plan: /lib64/libm.so.6: version `GLIBC_2.44' not found
# `[ -x ]` is true for it. So the fixture took the branch meant for a present
# binary, the fold failed for an environment reason, and the precondition
# reported FAIL. Every gate on that host was red from 19:07Z at a head that had
# been green while target/release was empty.
#
# WHY THIS DRIVES A SCRATCH CHECKOUT rather than exporting TILLANDSIAS_PLAN_BIN.
# The probe honours an explicit override on EXISTENCE alone, deliberately, so
# that a stub failing the way a STALE binary fails stays distinguishable from an
# absent one. Setting the override therefore reproduces a DIFFERENT condition
# than pirria's, where no override is set and the unlinkable ELF simply sits at
# target/release. Measured while writing this: the override route leaves the
# hook's own lane blaming the ledger ("tillandsias-plan check refused the folded
# ledger") for an instrument failure — a real defect, but a different one, filed
# separately. A pin that reproduced the wrong condition would certify the wrong
# fix.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="scripts/test-pre-push-issue-capture-lane.sh"
fail=0; pass=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/plan-runnability.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# A scratch CHECKOUT: the fixture derives its own ROOT from BASH_SOURCE, so a
# copy under $W/scripts sees $W as the checkout and $W/target/release as the
# place cycle-preflight would have built into.
mkdir -p "$W/scripts/hooks" "$W/target/release"
cp "$ROOT/$FIXTURE" "$W/scripts/" || exit 2
cp "$ROOT/scripts/hooks/pre-push-local-gate.sh" "$W/scripts/hooks/" || exit 2
for f in plan-binary-probe.sh gate-stamp.sh common.sh check-issue-citation-convention.sh; do
    cp "$ROOT/scripts/$f" "$W/scripts/" 2>/dev/null || true
done
chmod +x "$W/scripts"/*.sh "$W/scripts/hooks"/*.sh 2>/dev/null || true

# The unlinkable ELF, in the shape pirria measured: present, executable, and
# dead on exec. 127 is what a failed dynamic link exits with.
cat > "$W/target/release/tillandsias-plan" <<'STUB'
#!/usr/bin/env bash
echo "$0: /lib64/libm.so.6: version \`GLIBC_2.44' not found" >&2
exit 127
STUB
chmod +x "$W/target/release/tillandsias-plan"

# No override, no inherited target dir, AND NO PATH FALLBACK. The probe's
# candidate list ends with `command -v tillandsias-plan`, so on a host with the
# binary installed it correctly steps over the unlinkable ELF and resolves the
# PATH copy — which is the RIGHT behaviour and the wrong condition to pin. The
# first run of this fixture did exactly that and reported "the scratch base
# ledger folds", testing nothing. pirria's toolbox has no such fallback, so the
# pin must remove it or it certifies a path that host never takes.
_min_path=/usr/bin:/bin
out="$(cd "$W" && env -u TILLANDSIAS_PLAN_BIN -u CARGO_TARGET_DIR "PATH=$_min_path" \
        bash "$W/$FIXTURE" 2>&1)"; rc=$?

# NON-VACUITY: prove the stripped PATH really removed the fallback, or arm 1
# below could pass because the fixture died early for an unrelated reason.
if command -v tillandsias-plan >/dev/null 2>&1 \
   && env "PATH=$_min_path" command -v tillandsias-plan >/dev/null 2>&1; then
    bad "the stripped PATH still resolves tillandsias-plan; this pin is not testing the toolbox condition"
fi

# ── 1. It SKIPS, and says why ──────────────────────────────────────────────
case "$out" in
    *"skip:plan-binary-not-runnable-here"*) ok "an unlinkable binary produces a NAMED skip" ;;
    *) bad "no named skip for an unlinkable binary"; printf '%s\n' "$out" | tail -20 | sed 's/^/      /' >&2 ;;
esac

# The reason must carry the instrument's own words, not a generic label: the
# whole cost of pirria's day was not knowing WHY.
case "$out" in
    *"GLIBC_2.44"*) ok "the skip carries the linker's own message" ;;
    *) bad "the skip does not name the underlying reason" ;;
esac

# ── 2. It does NOT fail the precondition ───────────────────────────────────
case "$out" in
    *"PRECONDITION — the scratch base ledger does not fold"*)
        bad "the precondition still FAILS on an unlinkable binary — this is pirria's red gate" ;;
    *) ok "the precondition does not fail on an unlinkable binary" ;;
esac

# ── 3. The lane arms still ran and passed ──────────────────────────────────
# A skip that also abandoned the behavioural arms would be a green that
# measured nothing — the failure mode this whole family keeps producing.
if [ "$rc" -eq 0 ]; then
    ok "the fixture still returns success with the ledger arms exercised"
else
    bad "the fixture failed overall (rc=$rc) despite skipping the precondition"
    printf '%s\n' "$out" | grep -E '^FAIL' | head -5 | sed 's/^/      /' >&2
fi

# ── 4. CONTROL: a RUNNABLE binary must still exercise the ledger arms ──────
# Criterion 3. Without this the fix could be "skip always", which would pass
# every arm above while removing the validation the lane depends on.
ctl_bin="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || ctl_bin=""
if [ -z "$ctl_bin" ]; then
    echo "skip: no runnable plan binary on this host, control arm not attempted" >&2
else
    ctl="$(cd "$ROOT" && bash "$FIXTURE" 2>&1)"; ctl_rc=$?
    if [ "$ctl_rc" -eq 0 ] && printf '%s' "$ctl" | grep -q 'PRECONDITION: the scratch base ledger folds'; then
        ok "CONTROL: a runnable binary still folds the base and runs the ledger arms"
    else
        bad "CONTROL: a runnable binary no longer exercises the ledger arms (rc=$ctl_rc)"
        printf '%s\n' "$ctl" | grep -E '^FAIL|skip:' | head -5 | sed 's/^/      /' >&2
    fi
fi

echo "plan-binary-runnability: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
