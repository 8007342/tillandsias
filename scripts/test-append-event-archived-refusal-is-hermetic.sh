#!/usr/bin/env bash
# @trace order:1564-lk9f
#
# test-append-event-archived-refusal-is-hermetic.sh — the 896-f8ti fixture
# (scripts/test-append-event-archived-refusal.sh) must not be able to leave a
# write behind in the checkout it runs from, however it dies.
#
# WHY. MEASURED 2026-10-09 on macuahuitl: the v56.10.9.1 ./build.sh --ci-full
# left plan/index.d/20261009t080546z-12a361a8-fixture.yaml (host: fixture,
# carrying the fixture's own FIXTURE_MARK) in the real checkout, and
# scripts/land-queue.sh refused to start (fail:land-queue:dirty-tree). The
# live-accept arm wrote into the LIVE plan/index.d and relied on an EXIT trap
# to reap it; a trap does not run on SIGKILL, OOM or a tool cap.
#
#   1 SIGKILL    run the fixture in a scratch checkout, SIGKILL its whole process
#                group right after the live-accept arm's append-event succeeded,
#                and require `git status --porcelain` of that checkout to be
#                empty. Pre-fix: one host: fixture fragment left in plan/index.d.
#   2 REFUSAL    NEGATIVE CONTROL: when append-event refuses the fragment-only
#                packet, the fixture still goes red naming the refusal — the
#                699-usxc property is asserted, not skipped.
#   3 CLEAN RUN  an uninterrupted run passes and leaves the checkout clean.
#
# HERMETIC ITSELF: every arm runs in a fresh scratch git repo seeded from this
# tree's scripts/ and plan/, under target/plan-scratch (never /tmp), so even the
# pre-fix red leaks into the scratch copy and never into this checkout. The
# SIGKILL is timed by a shim plan binary (TILLANDSIAS_PLAN_BIN, honoured on
# existence by plan-binary-probe.sh) that marks the moment the live-accept
# append-event returned — no sleep-and-hope.
#
# EVERY ARM RUNS WITH ITS SCRATCH CHECKOUT AS CWD. The pre-fix fixture passes
# no --index, so append-event resolves plan/ from the CWD while the EXIT trap
# reaps under the script's ROOT: run from elsewhere, the two disagree. The first
# draft of this file ran it from the real checkout and leaked two fragments
# into it (yoga, 2026-10-09T19:36Z) — the defect, reproduced by its own test.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
REAL_PLAN="$(cd "$ROOT" && resolve_plan_binary)" || REAL_PLAN=""
case "$REAL_PLAN" in ./*) REAL_PLAN="$ROOT/${REAL_PLAN#./}" ;; esac
if [ -z "$REAL_PLAN" ]; then
    echo "skip:append-event-archived-refusal-is-hermetic:no-plan-binary"
    exit 0
fi
if ! command -v setsid >/dev/null 2>&1; then
    echo "skip:append-event-archived-refusal-is-hermetic:no-setsid"
    exit 0
fi

mkdir -p "$ROOT/target/plan-scratch"
W="$(mktemp -d "$ROOT/target/plan-scratch/append-event-hermetic.XXXXXX")"; trap 'rm -rf "$W"' EXIT INT TERM
GC=(-c user.email=f@f -c user.name=f -c commit.gpgsign=false)

# Only the ledger the fold reads (index.yaml, index.d/, archive/), and ONE arm's
# repo at a time, removed after its arm: a forge checkout is a tmpfs of a few
# hundred MB, and three whole-plan/ seeds plus the fixture's own scratch copy
# filled it on the first run (yoga, 2026-10-09).
seed() { # seed <dir>: a fresh repo holding this tree's scripts/ and ledger
    mkdir -p "$1/plan"
    cp -R "$ROOT/scripts" "$1/scripts"
    cp -R "$ROOT/plan/index.yaml" "$ROOT/plan/index.d" "$ROOT/plan/archive" "$1/plan/"
    cp "$ROOT/.gitignore" "$1/.gitignore"
    git -C "$1" init -q
    git -C "$1" "${GC[@]}" add -A
    git -C "$1" "${GC[@]}" commit -qm seed
}

# The shim passes every call through, except the live-accept arm's — keyed on
# the summary text that arm alone carries. MODE=kill: run it, mark, and hold so
# the harness can SIGKILL the group. MODE=refuse: refuse it like a broken fix.
SHIM="$W/shim/tillandsias-plan"
mkdir -p "$W/shim"
cat > "$SHIM" <<'SH'
#!/usr/bin/env bash
case "$*" in
    *"699-usxc preserved"*)
        if [ "$HERMETIC_SHIM_MODE" = refuse ]; then
            echo "error: refused by the hermetic shim" >&2
            exit 1
        fi
        "$HERMETIC_REAL_PLAN" "$@"; rc=$?
        if [ "$rc" -eq 0 ]; then : > "$HERMETIC_MARK"; sleep 120; fi
        exit "$rc" ;;
esac
exec "$HERMETIC_REAL_PLAN" "$@"
SH
chmod +x "$SHIM"

# ── ARM 1: SIGKILL right after the live-accept write ───────────────────────
S="$W/s1"; seed "$S"
MARK="$W/s1.mark"
(cd "$S" && HERMETIC_SHIM_MODE=kill HERMETIC_REAL_PLAN="$REAL_PLAN" HERMETIC_MARK="$MARK" \
    TILLANDSIAS_PLAN_BIN="$SHIM" \
    exec setsid bash scripts/test-append-event-archived-refusal.sh) >"$W/s1.log" 2>&1 &
pid=$!
waited=0
while [ ! -e "$MARK" ] && kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 600 ]; do
    sleep 0.2; waited=$((waited + 1))
done
if [ ! -e "$MARK" ]; then
    kill -KILL -- "-$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    bad "ARM 1: could not run — the live-accept arm never returned success (log: $(tr '\n' ' ' <"$W/s1.log"))"
else
    kill -KILL -- "-$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    dirty="$(git -C "$S" status --porcelain)"
    if [ -z "$dirty" ]; then
        ok "ARM 1: SIGKILL after the live-accept arm leaves the checkout clean"
    else
        bad "ARM 1: SIGKILL after the live-accept arm left the checkout dirty: $(printf '%s' "$dirty" | tr '\n' ' ')"
    fi
fi

rm -rf "$W/s1"

# ── ARM 2: NEGATIVE CONTROL — a refused fragment-only packet is still red ───
S="$W/s2"; seed "$S"
out2="$(cd "$S" && HERMETIC_SHIM_MODE=refuse HERMETIC_REAL_PLAN="$REAL_PLAN" HERMETIC_MARK="$W/s2.mark" \
    TILLANDSIAS_PLAN_BIN="$SHIM" bash scripts/test-append-event-archived-refusal.sh 2>&1)"
rc2=$?
if [ "$rc2" -ne 0 ] && grep -q 'a LIVE packet was REFUSED' <<<"$out2"; then
    ok "ARM 2: a refused fragment-only packet still reddens the fixture (699-usxc asserted)"
else
    bad "ARM 2: rc=$rc2 — a refused live packet did not redden the fixture: $(tr '\n' ' ' <<<"$out2")"
fi

rm -rf "$W/s2"

# ── ARM 3: an uninterrupted run is green and clean ─────────────────────────
S="$W/s3"; seed "$S"
out3="$(cd "$S" && TILLANDSIAS_PLAN_BIN="$REAL_PLAN" bash scripts/test-append-event-archived-refusal.sh 2>&1)"
rc3=$?
dirty3="$(git -C "$S" status --porcelain)"
if [ "$rc3" -eq 0 ] && [ -z "$dirty3" ] && grep -q 'a LIVE packet still accepts events' <<<"$out3"; then
    ok "ARM 3: an uninterrupted run passes, exercises the live-accept arm, and leaves the checkout clean"
else
    bad "ARM 3: rc=$rc3 dirty=[$(printf '%s' "$dirty3" | tr '\n' ' ')] out=$(tr '\n' ' ' <<<"$out3")"
fi

rm -rf "$W/s3"

echo "append-event-archived-refusal-is-hermetic: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ok:append-event-archived-refusal-is-hermetic:$pass"
