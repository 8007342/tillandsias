#!/usr/bin/env bash
# @trace order:874-w2gc
# test-salvage-net.sh — pin the salvage net END TO END: push, round-trip,
# same-day collision, deletion protection, exemption ordering, and the sweep
# that makes rescued work visible.
#
# The incident chain this pins: 872-c9nd (four hours of work deleted with a
# fresh clone while three cycles wrote prose about it), 874-s8vf (the net's
# first push was refused by a guard that ran before the exemption), 874-w2gc
# (a rescue nobody consumes is prose-with-extra-steps; a deletion nobody
# questions is the original incident with extra steps).
#
# Hermetic: every scenario runs against scratch repos and a local bare
# "origin"; the real checkout is never touched. Scenario filter: pass a name
# (roundtrip|collision|deletion|ordering|sweep) to run one; default all.
set -uo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SALVAGE="$REAL_ROOT/scripts/salvage-dirty-worktree.sh"
SWEEP="$REAL_ROOT/scripts/sweep-salvage-refs.sh"
HOOK="$REAL_ROOT/scripts/hooks/pre-push-local-gate.sh"
ONLY="${1:-all}"
fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }
want() { [ "$ONLY" = all ] || [ "$ONLY" = "$1" ]; }

# A scratch work repo whose `origin` is a local bare — the salvage script's
# whole remote surface.
mk_fixture() {
    local d="$1"
    git init -q --bare "$d/origin.git"
    git init -q -b main "$d/work"
    ( cd "$d/work" \
        && git remote add origin "$d/origin.git" \
        && echo base > tracked.txt \
        && git add tracked.txt \
        && git -c user.email=t@t -c user.name=t commit -q -m seed \
        && git push -q origin main )
}

ZEROS="0000000000000000000000000000000000000000"
FAKESHA="1111111111111111111111111111111111111111"

# ── 1. round-trip: dirty content survives push and comes back intact ─────────
if want roundtrip; then
    D="$(mktemp -d "${TMPDIR:-/tmp}/salvage-net-test.XXXXXX")"
    mk_fixture "$D"
    echo edited > "$D/work/tracked.txt"
    echo brand-new > "$D/work/untracked.txt"
    out="$(TILLANDSIAS_SALVAGE_ROOT="$D/work" bash "$SALVAGE" fixture-slug | tail -1)"
    case "$out" in
        ok:salvaged:refs/heads/salvage/*/*-fixture-slug:*) ok "salvage push lands with the documented grammar" ;;
        *) bad "salvage verdict: $out" ;;
    esac
    sha="${out##*:}"
    # The worktree and the REAL index must be untouched by the salvage.
    dirt="$(git -C "$D/work" status --porcelain=v1 --untracked-files=all | sort | tr '\n' '|')"
    [ "$dirt" = " M tracked.txt|?? untracked.txt|" ] \
        && ok "salvage mutated neither worktree nor index" \
        || bad "worktree state changed under salvage: $dirt"
    # Round-trip: a third party fetches the ref and reads the exact dirt back.
    git init -q -b main "$D/reader"
    ( cd "$D/reader" && git remote add origin "$D/origin.git" && git fetch -q origin "+refs/heads/salvage/*:refs/salvage/*" )
    got_tracked="$(git -C "$D/reader" show "$sha:tracked.txt" 2>/dev/null)"
    got_untracked="$(git -C "$D/reader" show "$sha:untracked.txt" 2>/dev/null)"
    [ "$got_tracked" = edited ] && [ "$got_untracked" = brand-new ] \
        && ok "round-trip: modified AND untracked content both recovered byte-exact" \
        || bad "round-trip content: tracked=$got_tracked untracked=$got_untracked"
    rm -rf "$D"
fi

# ── 2. same-day collision: two salvages, same host, same day, BOTH land ──────
if want collision; then
    D="$(mktemp -d "${TMPDIR:-/tmp}/salvage-net-test.XXXXXX")"
    mk_fixture "$D"
    echo first > "$D/work/tracked.txt"
    out1="$(TILLANDSIAS_SALVAGE_ROOT="$D/work" bash "$SALVAGE" twice | tail -1)"
    echo second > "$D/work/tracked.txt"
    out2="$(TILLANDSIAS_SALVAGE_ROOT="$D/work" bash "$SALVAGE" twice | tail -1)"
    case "$out2" in
        ok:salvaged:*) ok "second same-day salvage lands instead of dying non-fast-forward" ;;
        *) bad "second salvage: $out2" ;;
    esac
    n="$(git -C "$D/origin.git" for-each-ref --format='%(refname)' refs/heads/salvage | wc -l | tr -d ' ')"
    [ "$n" = 2 ] && ok "both same-day refs exist on the remote (exit criterion 2)" \
                 || bad "expected 2 salvage refs on origin, found $n"
    ref1="${out1#ok:salvaged:}"; ref1="${ref1%:*}"
    ref2="${out2#ok:salvaged:}"; ref2="${ref2%:*}"
    [ "$ref1" != "$ref2" ] && ok "collision resolved by name, not by overwrite" \
                           || bad "both salvages used the same ref: $ref1"
    rm -rf "$D"
fi

# ── 3. deletion protection: the exemption no longer waves deletions through ──
if want deletion; then
    D="$(mktemp -d "${TMPDIR:-/tmp}/salvage-net-test.XXXXXX")"
    mkdir -p "$D/repo"; ( cd "$D/repo" && git init -q -b main . )
    REFLINE="(delete) $ZEROS refs/heads/salvage/host/20260101-x $FAKESHA"
    ( cd "$D/repo" && printf '%s\n' "$REFLINE" | bash "$HOOK" origin file:///dev/null >/dev/null 2>"$D/err" )
    rc=$?
    grep -q "874-w2gc" "$D/err" && [ "$rc" -ne 0 ] \
        && ok "deleting a salvage ref is refused, naming the decision (rc=$rc)" \
        || bad "deletion slipped through: rc=$rc err=$(head -1 "$D/err")"
    ( cd "$D/repo" && printf '%s\n' "$REFLINE" | TILLANDSIAS_SALVAGE_DELETE_OK=1 bash "$HOOK" origin file:///dev/null >/dev/null 2>&1 )
    rc=$?
    [ "$rc" -eq 0 ] && ok "the explicit override still permits a conscious deletion" \
                    || bad "override did not permit deletion: rc=$rc"
    # NEGATIVE CONTROL: a normal salvage UPDATE (non-zero local sha) must stay
    # exempt — protection that also blocks rescues would resurrect 874-s8vf.
    ( cd "$D/repo" && printf '%s\n' "refs/heads/x $FAKESHA refs/heads/salvage/host/20260101-x $ZEROS" | bash "$HOOK" origin file:///dev/null >/dev/null 2>&1 )
    rc=$?
    [ "$rc" -eq 0 ] && ok "a rescue push is still exempt (protection blocks only deletion)" \
                    || bad "rescue push refused by deletion protection: rc=$rc"
    rm -rf "$D"
fi

# ── 4. exemption ordering: salvage escapes a worktree-state guard that would
#       refuse it (exit criterion 4 — goes red if the exemption is reordered) ─
if want ordering; then
    D="$(mktemp -d "${TMPDIR:-/tmp}/salvage-net-test.XXXXXX")"
    mkdir -p "$D/repo/scripts" "$D/repo/cheatsheets"
    ( cd "$D/repo" && git init -q -b main . )
    cp "$REAL_ROOT/scripts/stage-image-cheatsheets.sh" "$D/repo/scripts/"
    echo stray > "$D/repo/cheatsheets/fixture.md"
    # COUNTERFACTUAL FIRST: prove this fixture's tree DOES make the cheatsheet
    # guard refuse a normal push — otherwise a pass below proves nothing.
    ( cd "$D/repo" && printf '%s\n' "refs/heads/main $FAKESHA refs/heads/main $ZEROS" | bash "$HOOK" origin file:///dev/null >/dev/null 2>"$D/err" )
    rc=$?
    { [ "$rc" -ne 0 ] && grep -qi cheatsheet "$D/err"; } \
        && ok "counterfactual: the cheatsheet guard refuses a NORMAL push from this tree" \
        || bad "fixture did not trip the guard (rc=$rc) — ordering test has no teeth"
    # THE PIN: the same tree, salvage-only refs — must exit 0, which is only
    # possible if the exemption runs BEFORE the guard that just refused.
    ( cd "$D/repo" && printf '%s\n' "refs/heads/x $FAKESHA refs/heads/salvage/host/20260101-x $ZEROS" | bash "$HOOK" origin file:///dev/null >/dev/null 2>&1 )
    rc=$?
    [ "$rc" -eq 0 ] && ok "salvage-only push exits 0 from the same tree — exemption is the first decision" \
                    || bad "salvage push refused (rc=$rc): the exemption is no longer the hook's first decision"
    rm -rf "$D"
fi

# ── 5. sweep: unseen refs become ledger events exactly once; refusals report ─
if want sweep; then
    D="$(mktemp -d "${TMPDIR:-/tmp}/salvage-net-test.XXXXXX")"
    mk_fixture "$D"
    echo dirt > "$D/work/tracked.txt"
    TILLANDSIAS_SALVAGE_ROOT="$D/work" bash "$SALVAGE" swept >/dev/null
    # Sweep root: a minimal ledger layout plus a stub plan bin that RECORDS its
    # argv and writes a fragment, so run 2 can prove idempotence via the same
    # seen-detection production uses.
    mkdir -p "$D/root/plan/index.d" "$D/root/.git"
    ( cd "$D/root" && git init -q -b main . >/dev/null 2>&1 )
    ( cd "$D/root" && git remote add origin "$D/origin.git" )
    : > "$D/root/plan/index.yaml"
    cat > "$D/stub-plan" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$D/stub-calls.log"
printf 'events-from-stub: %s\n' "\$*" >> "$D/root/plan/index.d/stub.yaml"
exit 0
STUB
    chmod +x "$D/stub-plan"
    mkdir -p "$D/state"
    printf '{"r":1}\n{"r":2}\n{"r":3}\n' > "$D/state/overlap-refusals.jsonl"
    env_sweep() {
        TILLANDSIAS_SALVAGE_ROOT="$D/root" \
        TILLANDSIAS_SWEEP_PLAN_BIN="$D/stub-plan" \
        TILLANDSIAS_CYCLE_STATE_DIR="$D/state" \
        TILLANDSIAS_AGENT_ID=linux-fixture-sweep-20260101t000000z \
            bash "$SWEEP" "$@"
    }
    out="$(env_sweep | tail -1)"
    case "$out" in
        ok:salvage-sweep:refs=1:new=1:filed=0:refusals-new=3) ok "report mode counts without writing" ;;
        *) bad "report-mode verdict: $out" ;;
    esac
    [ -f "$D/stub-calls.log" ] && bad "report mode invoked the plan writer" || ok "report mode never touched the ledger"
    out="$(env_sweep --apply | tail -1)"
    case "$out" in
        ok:salvage-sweep:refs=1:new=1:filed=1:refusals-new=3) ok "apply mode files the unseen ref (exit criterion 1)" ;;
        *) bad "apply-mode verdict: $out" ;;
    esac
    grep -q "append-event the-salvage-net-had-never-caught-anything-and-could-not progress" "$D/stub-calls.log" \
        && grep -q "refs/heads/salvage/" "$D/stub-calls.log" \
        && ok "the event lands on the salvage packet and names the ref" \
        || bad "stub argv wrong: $(cat "$D/stub-calls.log")"
    out="$(env_sweep --apply | tail -1)"
    case "$out" in
        ok:salvage-sweep:refs=1:new=0:filed=0:refusals-new=0) ok "second sweep is idempotent; refusal cursor advanced" ;;
        *) bad "idempotence verdict: $out" ;;
    esac
    rm -rf "$D"
fi

if [ "$fail" -eq 0 ]; then
    echo "ok:salvage-net-fixture:all"
    exit 0
fi
echo "fail:salvage-net-fixture"
exit 1
