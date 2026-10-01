#!/usr/bin/env bash
# @trace order:1437-664a, order:1520-zjmk, spec:ci-release
#
# Fixture for scripts/relay-preflight.sh (1437-664a): the SIX ARMS the
# packet's verifiable_closure names, over a scratch repo carrying a base
# branch and two work refs. The cargo and litmus phases are stubbed via
# TILLANDSIAS_RELAY_PREFLIGHT_STUB so this runs in seconds; none of the six
# arms below ever touches a crates/ or openspec/ path, so those phases
# no-op on their own selection logic anyway — the stub is set regardless,
# because the packet requires it and a future arm may add one.
#
# PRE-FIX RESULT: FAILS — scripts/relay-preflight.sh does not exist; the
# relay lane hand-types the sequence today.
#
# ALL SCRATCH REPOS LIVE UNDER target/plan-scratch (mktemp -d there), never
# in the real checkout or its .git, and every git call carries an EXPLICIT
# identity (-c user.email/-c user.name) so this fixture cannot depend on, or
# pollute, any operator or host git config.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNDER_TEST="$ROOT/scripts/relay-preflight.sh"
[ -f "$UNDER_TEST" ] || { echo "fail:relay-preflight-fixture:0/6 (scripts/relay-preflight.sh not present)"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "skip:relay-preflight-fixture:no-git"; exit 0; }

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/relay-preflight.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

pass=0
total=8
ok()  { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1: $2"; }

GC=(-c user.email=fixture@relay-preflight.invalid -c user.name=relay-preflight-fixture)
export TILLANDSIAS_RELAY_PREFLIGHT_STUB=1

# The scratch repos carry no plan binary, so the deciders that need one
# (check-added-fragments-parse) must be handed THIS checkout's, resolved here
# and absolutised BEFORE any cd: the default-target regime strips every PATH
# binary and unsets TILLANDSIAS_PLAN_BIN, and a scratch cwd resolves nothing
# (the 84f37ff24 remedy; land113 relay-fix).
. "$ROOT/scripts/plan-binary-probe.sh" 2>/dev/null || true
_pb="$(cd "$ROOT" && resolve_plan_binary 2>/dev/null)" || _pb=""
case "$_pb" in ./*) _pb="$ROOT/${_pb#./}" ;; esac
[ -n "$_pb" ] && export TILLANDSIAS_PLAN_BIN="$_pb"

# The deciders relay-preflight.sh shells out to, by their OWN relative
# location — copied into every scratch repo's scripts/ dir so they judge the
# SCRATCH tree, never this checkout's.
DECIDER_FILES="timing-log.sh plan-binary-probe.sh check-sigpipe-verdict-pipelines-added.sh check-plan-binary-probe-usage.sh check-litmus-pin-claims.sh check-script-exec-bits.sh check-added-fragments-parse.sh check-scorable-obligation-added.sh check-gate-step-regimes.sh check-added-test-is-referenced.sh check-refusal-affordance-added.sh check-rust-source-pin-added.sh check-no-python-scripts.sh check-jq-callsite-ratchet.sh preflight-fixtures-default-target.sh check-issue-citation-convention.sh trace-coverage.sh litmus-covering-specs.sh"

# _seed <dir>: a fresh repo at <dir> with relay-preflight.sh and every decider
# it calls, one base commit, branch "linux-next".
# 1384-ddua: the scratch clones run the Lua decider through the checkout's
# own plan binary, which must know `script run`.
if [ -z "${TILLANDSIAS_PLAN_BIN:-}" ]; then
    TILLANDSIAS_PLAN_BIN="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || TILLANDSIAS_PLAN_BIN=""
    case "$TILLANDSIAS_PLAN_BIN" in ./*) TILLANDSIAS_PLAN_BIN="$ROOT/${TILLANDSIAS_PLAN_BIN#./}" ;; esac
    export TILLANDSIAS_PLAN_BIN
fi

_seed() {
    local d="$1"
    mkdir -p "$d/scripts/lib"
    cp "$UNDER_TEST" "$d/scripts/relay-preflight.sh"
    local f
    for f in $DECIDER_FILES; do
        [ -f "$ROOT/scripts/$f" ] && cp "$ROOT/scripts/$f" "$d/scripts/$f"
    done
    # check-script-exec-bits.sh's own filtering lives in a sibling awk file;
    # check-added-test-is-referenced.sh declares its reference surfaces in a
    # sibling manifest. Both are data these deciders read, not code this
    # script calls, so DECIDER_FILES (a list of .sh basenames) never covers
    # them.
    # 1384-ddua: check-bash-dialect is a Lua decider on the one runner.
    mkdir -p "$d/scripts/lua"
    cp "$ROOT/scripts/lua/check-bash-dialect.lua" "$d/scripts/lua/"
    [ -f "$ROOT/scripts/lib/exec-bits-filter.awk" ] && cp "$ROOT/scripts/lib/exec-bits-filter.awk" "$d/scripts/lib/"
    [ -f "$ROOT/scripts/test-reference-surfaces.manifest" ] && cp "$ROOT/scripts/test-reference-surfaces.manifest" "$d/scripts/"
    chmod +x "$d"/scripts/*.sh
    # trace-coverage.sh --gate (whole-tree: every @trace spec: token in the
    # copied deciders' own headers) needs openspec/specs/<name>/spec.md to
    # exist or it reads every one of those tokens as a brand-new ghost trace
    # against an empty baseline. The copied deciders carry exactly these
    # three (spec:ci-release, spec:meta-orchestration,
    # spec:methodology-accountability) — stub them, not the real prose.
    local _s
    for _s in ci-release meta-orchestration methodology-accountability; do
        mkdir -p "$d/openspec/specs/$_s"
        printf '# %s\n\nStub spec for the relay-preflight fixture.\n' "$_s" > "$d/openspec/specs/$_s/spec.md"
    done
    echo "base" > "$d/README.md"
    git -C "$d" init -q -b linux-next
    git -C "$d" "${GC[@]}" add -A
    git -C "$d" "${GC[@]}" commit -qm base
}

# _origin <seed-dir> <bare-dir>: push seed's linux-next to a bare "origin".
# The bare repo's own HEAD defaults to whatever branch name this host's git
# config picks (master/main), which is neither pushed nor present — a clone
# then fails to check anything out ("remote HEAD refers to nonexistent
# ref"). Point HEAD at linux-next explicitly before anything is pushed.
_origin() {
    git init -q --bare "$2"
    git -C "$2" symbolic-ref HEAD refs/heads/linux-next
    git -C "$1" remote add origin "$2"
    git -C "$1" "${GC[@]}" push -q origin linux-next
}

# _clone <bare-dir> <clone-dir>: a working clone the fixture invokes the
# script FROM (relay-preflight.sh cd's to its own dirname/.., so invoking it
# by path inside <clone-dir> makes <clone-dir> the ROOT it operates on).
_clone() {
    git clone -q "$1" "$2"
    # LOCAL repo config, not -c overrides: relay-preflight.sh itself calls
    # plain `git merge` (it cannot be handed -c flags), so the identity a
    # merge commit needs must already live in this clone's own .git/config —
    # never inherited from any host or operator global config.
    git -C "$2" config user.email fixture@relay-preflight.invalid
    git -C "$2" config user.name relay-preflight-fixture
    git -C "$2" checkout -q linux-next
}

# Output capture files MUST live OUTSIDE the clone's working tree: a
# redirect target is created the instant the subshell starts, before
# relay-preflight.sh's own first line runs, so a file inside $1 would make
# arm6's OWN test apparatus trip the dirty-worktree check it exists to
# pin (measured: every arm read dirty until this moved outside the tree).
_run() { # <clone-dir> <args...> -> sets OUT, ERR, RC
    local _o _e
    _o="$(mktemp "$W/run-out.XXXXXX")"; _e="$(mktemp "$W/run-err.XXXXXX")"
    ( cd "$1" && bash scripts/relay-preflight.sh "${@:2}" >"$_o" 2>"$_e" )
    RC=$?
    OUT="$(cat "$_o" 2>/dev/null)"
    ERR="$(cat "$_e" 2>/dev/null)"
    rm -f "$_o" "$_e"
}

# ── shared base + two clean work refs, reused by arms 1, 3 and 4 ──────────
BASE_SEED="$W/base-seed"
_seed "$BASE_SEED"
# arm 4's target: a non-test script, and a fixture that MENTIONS it by bytes.
cat > "$BASE_SEED/scripts/foo-target.sh" <<'EOF'
#!/usr/bin/env bash
echo hi
EOF
chmod +x "$BASE_SEED/scripts/foo-target.sh"
cat > "$BASE_SEED/scripts/test-mentions-foo.sh" <<'EOF'
#!/usr/bin/env bash
# exercises scripts/foo-target.sh
echo "ok: mentions-foo 1"
exit 0
EOF
chmod +x "$BASE_SEED/scripts/test-mentions-foo.sh"
git -C "$BASE_SEED" "${GC[@]}" add -A
git -C "$BASE_SEED" "${GC[@]}" commit -qm "add foo-target and its fixture"
BASE_BARE="$W/base-origin.git"
_origin "$BASE_SEED" "$BASE_BARE"

CLONE_A="$W/clone-a"
_clone "$BASE_BARE" "$CLONE_A"
git -C "$CLONE_A" "${GC[@]}" checkout -qb work/a
echo "change a" > "$CLONE_A/a.txt"
git -C "$CLONE_A" "${GC[@]}" add -A
git -C "$CLONE_A" "${GC[@]}" commit -qm "work/a: harmless file"
git -C "$CLONE_A" "${GC[@]}" checkout -qb work/b linux-next
echo "change b" > "$CLONE_A/b.txt"
git -C "$CLONE_A" "${GC[@]}" add -A
git -C "$CLONE_A" "${GC[@]}" commit -qm "work/b: harmless file"
git -C "$CLONE_A" "${GC[@]}" checkout -q linux-next

# ── arm 1 ────────────────────────────────────────────────────────────────────
_run "$CLONE_A" work/a work/b --base origin/linux-next
_a1_ok=1
case "$OUT" in
    ok:relay-preflight:*:refs=2\ deciders=*\ fmt=*\ fixtures=*\ crates=*\ litmus=*) ;;
    *) _a1_ok=0 ;;
esac
_a1_lines="$(printf '%s\n' "$OUT" | grep -c .)"
if [ "$_a1_ok" = 1 ] && [ "$_a1_lines" = 1 ] && [ "$RC" = 0 ] && grep -q '^item: ' <<<"$ERR"; then
    ok "arm1: one ok: line, refs=2, per-item lines on stderr"
else
    bad "arm1" "rc=$RC out=[$OUT]"
    printf '%s\n' "$ERR" | sed 's/^/    err: /' | head -20
fi

# ── arm 3: --plan determinism ────────────────────────────────────────────────
CLONE_C="$W/clone-c"
_clone "$BASE_BARE" "$CLONE_C"
git -C "$CLONE_C" "${GC[@]}" checkout -qb work/a
echo "change a" > "$CLONE_C/a.txt"
git -C "$CLONE_C" "${GC[@]}" add -A
git -C "$CLONE_C" "${GC[@]}" commit -qm "work/a: harmless file"
git -C "$CLONE_C" "${GC[@]}" checkout -qb work/b linux-next
echo "change b" > "$CLONE_C/b.txt"
git -C "$CLONE_C" "${GC[@]}" add -A
git -C "$CLONE_C" "${GC[@]}" commit -qm "work/b: harmless file"
git -C "$CLONE_C" "${GC[@]}" checkout -q linux-next

_run "$CLONE_C" --plan work/a work/b --base origin/linux-next
_plan1="$OUT"; _rc1="$RC"
git -C "$CLONE_C" "${GC[@]}" checkout -q linux-next
_run "$CLONE_C" --plan work/a work/b --base origin/linux-next
_plan2="$OUT"; _rc2="$RC"
if [ "$_rc1" = 0 ] && [ "$_rc2" = 0 ] && [ -n "$_plan1" ] && [ "$_plan1" = "$_plan2" ]; then
    ok "arm3: two --plan runs print byte-identical item lists"
else
    bad "arm3" "rc1=$_rc1 rc2=$_rc2"
    diff <(printf '%s\n' "$_plan1") <(printf '%s\n' "$_plan2") | sed 's/^/    diff: /' | head -20
fi

# ── arm 4: a diff touching scripts/foo-target.sh selects test-mentions-foo,
#    listed before it runs ──────────────────────────────────────────────────
CLONE_D="$W/clone-d"
_clone "$BASE_BARE" "$CLONE_D"
git -C "$CLONE_D" "${GC[@]}" checkout -qb work/touch-foo
printf '#!/usr/bin/env bash\necho hi\necho changed\n' > "$CLONE_D/scripts/foo-target.sh"
git -C "$CLONE_D" "${GC[@]}" add -A
git -C "$CLONE_D" "${GC[@]}" commit -qm "touch foo-target"
git -C "$CLONE_D" "${GC[@]}" checkout -q linux-next

_d_o="$(mktemp "$W/run-out.XXXXXX")"; _d_e="$(mktemp "$W/run-err.XXXXXX")"
( cd "$CLONE_D" && bash scripts/relay-preflight.sh work/touch-foo --base origin/linux-next >"$_d_o" 2>"$_d_e" )
_d_combined="$(cat "$_d_o" "$_d_e" 2>/dev/null)"
rm -f "$_d_o" "$_d_e"
_sel_line="$(grep -n 'item: fixture:test-mentions-foo selected' <<<"$_d_combined" | head -1 | cut -d: -f1)"
_run_line="$(grep -n 'item: fixture:test-mentions-foo ' <<<"$_d_combined" | grep -v selected | head -1 | cut -d: -f1)"
if [ -n "$_sel_line" ] && [ -n "$_run_line" ] && [ "$_sel_line" -lt "$_run_line" ]; then
    ok "arm4: touching scripts/foo-target.sh selects test-mentions-foo.sh, listed before it runs"
else
    bad "arm4" "sel_line=$_sel_line run_line=$_run_line"
    printf '%s\n' "$_d_combined" | sed 's/^/    /' | head -30
fi

# ── arm 2: a ref that makes check-bash-dialect red ──────────────────────────
CLONE_E="$W/clone-e"
_clone "$BASE_BARE" "$CLONE_E"
git -C "$CLONE_E" "${GC[@]}" checkout -qb work/bad-dialect
# ASSEMBLED, never spelled literally: check-bash-dialect's own gate
# scans THIS file's bytes too, and a literal bash4-ism here would trip it
# on its own fixture (the same reason litmus-covering-specs.sh assembles
# its "litmus:" prefix rather than spelling a fake claim outright).
_lower='$'"{x,,}"
printf '#!/usr/bin/env bash\nx="A"\ny=%s\necho "$y"\n' "$_lower" > "$CLONE_E/scripts/bad-dialect.sh"
chmod +x "$CLONE_E/scripts/bad-dialect.sh"
git -C "$CLONE_E" "${GC[@]}" add -A
git -C "$CLONE_E" "${GC[@]}" commit -qm "add an unguarded bash4-ism"
git -C "$CLONE_E" "${GC[@]}" checkout -q linux-next

_run "$CLONE_E" work/bad-dialect --base origin/linux-next
if [ "$RC" = 1 ] && [ "$OUT" = "refused:relay-preflight:deciders:check-bash-dialect" ]; then
    ok "arm2: check-bash-dialect red yields the exact refusal, exit 1, nothing later ran"
else
    bad "arm2" "rc=$RC out=[$OUT]"
    printf '%s\n' "$ERR" | sed 's/^/    err: /' | head -20
fi
# no later phase ran: no fixtures/crates/litmus item lines follow the refusal
if grep -qE '^item: (fixture:|cargo-test:|litmus:)' <<<"$ERR"; then
    bad "arm2-no-later-phase" "a later phase's item line appeared after the decider refusal"
fi

# ── arm 5: a conflicting ref, tree restored clean ───────────────────────────
CLONE_F="$W/clone-f"
_clone "$BASE_BARE" "$CLONE_F"
echo "trunk-version" > "$CLONE_F/conflict.txt"
git -C "$CLONE_F" "${GC[@]}" add -A
git -C "$CLONE_F" "${GC[@]}" commit -qm "trunk: conflict.txt"
git -C "$CLONE_F" "${GC[@]}" push -q origin linux-next
git -C "$CLONE_F" "${GC[@]}" checkout -qb work/conflict HEAD~1
echo "work-version" > "$CLONE_F/conflict.txt"
git -C "$CLONE_F" "${GC[@]}" add -A
git -C "$CLONE_F" "${GC[@]}" commit -qm "work/conflict: conflict.txt"
git -C "$CLONE_F" "${GC[@]}" checkout -q linux-next

_run "$CLONE_F" work/conflict --base origin/linux-next
_status_after="$(git -C "$CLONE_F" status --porcelain)"
_branch_after="$(git -C "$CLONE_F" symbolic-ref --short -q HEAD)"
if [ "$RC" = 2 ] && [ "$OUT" = "refused:relay-preflight:merge:merge-conflict:work/conflict" ] \
    && [ -z "$_status_after" ] && [ "$_branch_after" = "linux-next" ]; then
    ok "arm5: merge conflict refuses exit 2, tree restored clean on linux-next"
else
    bad "arm5" "rc=$RC out=[$OUT] status=[$_status_after] branch=$_branch_after"
    printf '%s\n' "$ERR" | sed 's/^/    err: /' | head -20
fi

# ── arm 6: NEGATIVE CONTROL — dirty worktree refused BEFORE any fetch ──────
CLONE_G="$W/clone-g"
_clone "$BASE_BARE" "$CLONE_G"
_relay_before="$(git -C "$CLONE_G" for-each-ref --format='%(refname)' refs/heads/relay/ | wc -l)"
echo "dirt" >> "$CLONE_G/README.md"
_run "$CLONE_G" work/a --base origin/linux-next
_relay_after="$(git -C "$CLONE_G" for-each-ref --format='%(refname)' refs/heads/relay/ | wc -l)"
if [ "$RC" = 1 ] && [ "$OUT" = "refused:relay-preflight:dirty-worktree" ] && [ "$_relay_before" = "$_relay_after" ]; then
    ok "arm6: a dirty worktree is refused before any fetch (no scratch relay/ branch appears)"
else
    bad "arm6" "rc=$RC out=[$OUT] relay_before=$_relay_before relay_after=$_relay_after"
    printf '%s\n' "$ERR" | sed 's/^/    err: /' | head -20
fi


# ── arm 7: a fixture that READS STDIN cannot end the loop early (1520-zjmk) ─
# The fixture loop is `while read; do _cap bash "$_fx"; done <<heredoc`, so a
# fixture inherits the loop's stdin. MEASURED on land115 (2026-09-30): the
# real test-preflight-front-door read it to EOF, the four fixtures sorted
# after it never ran, and the verdict still printed fixtures=6 and ok. Here
# test-zz-a drains stdin and test-zz-b refuses; the relay must run b and
# refuse naming it. PRE-FIX: a eats the list, b never runs, rc=0 — this arm
# FAILS.
Z_SEED="$W/zz-seed"
_seed "$Z_SEED"
printf '#!/usr/bin/env bash\necho v1\n' > "$Z_SEED/scripts/zz-subject.sh"
cat > "$Z_SEED/scripts/test-zz-a.sh" <<'EOF'
#!/usr/bin/env bash
# exercises scripts/zz-subject.sh, and drains whatever stdin it was handed
cat >/dev/null
echo "ok: zz-a 1"
EOF
cat > "$Z_SEED/scripts/test-zz-b.sh" <<'EOF'
#!/usr/bin/env bash
# exercises scripts/zz-subject.sh, and refuses
echo "FAIL: zz-b refuses on purpose"
exit 1
EOF
chmod +x "$Z_SEED"/scripts/zz-subject.sh "$Z_SEED"/scripts/test-zz-a.sh "$Z_SEED"/scripts/test-zz-b.sh
git -C "$Z_SEED" "${GC[@]}" add -A
git -C "$Z_SEED" "${GC[@]}" commit -qm "zz-subject and two fixtures that mention it"
Z_BARE="$W/zz-origin.git"
_origin "$Z_SEED" "$Z_BARE"
CLONE_Z="$W/clone-z"
_clone "$Z_BARE" "$CLONE_Z"
git -C "$CLONE_Z" "${GC[@]}" checkout -qb work/zz
printf '#!/usr/bin/env bash\necho v2\n' > "$CLONE_Z/scripts/zz-subject.sh"
git -C "$CLONE_Z" "${GC[@]}" add -A
git -C "$CLONE_Z" "${GC[@]}" commit -qm "work/zz: touch zz-subject"
git -C "$CLONE_Z" "${GC[@]}" checkout -q linux-next
_run "$CLONE_Z" work/zz --base origin/linux-next
if [ "$RC" != 0 ] && [ "$OUT" = "refused:relay-preflight:fixtures:test-zz-b" ]; then
    ok "arm7: a fixture that drains stdin does not end the loop; the next fixture runs and its refusal is reported"
else
    bad "arm7" "rc=$RC out=[$OUT] (pre-fix shape: rc=0 and an ok: verdict — test-zz-b never ran)"
    printf '%s\n' "$ERR" | grep -E 'fixture:' | sed 's/^/    err: /' | head -10
fi

# ── arm 8: a ref that DELETES a decider and repoints the tool (1522-ey4h) ──
# The pre-merge tool kept running its own decider list after the merge and
# refused at the deleted script ("No such file or directory"). The merged copy
# of the tool must take over, so the run reaches ok: and says it re-executed.
CLONE_H="$W/clone-h"
_clone "$BASE_BARE" "$CLONE_H"
git -C "$CLONE_H" "${GC[@]}" checkout -qb work/port
git -C "$CLONE_H" "${GC[@]}" rm -q scripts/check-no-python-scripts.sh
sed -i.bak -e 's/ check-no-python-scripts / /' -e '/^        check-no-python-scripts) /d' "$CLONE_H/scripts/relay-preflight.sh"
rm -f "$CLONE_H/scripts/relay-preflight.sh.bak"
git -C "$CLONE_H" "${GC[@]}" add -A
git -C "$CLONE_H" "${GC[@]}" commit -qm "port: retire check-no-python-scripts and repoint the tool"
git -C "$CLONE_H" "${GC[@]}" checkout -q linux-next
_run "$CLONE_H" work/port --base origin/linux-next
if [ "$RC" = 0 ] && grep -q '^ok:relay-preflight:' <<<"$OUT" && grep -q '^item: reexec:merged-copy ok' <<<"$ERR" \
   && ! grep -q 'No such file' <<<"$ERR"; then
    ok "arm8: a ref deleting a decider passes; the merged copy of the tool re-executed and ran (1522-ey4h)"
else
    bad "arm8" "rc=$RC out=[$OUT]"
    printf '%s\n' "$ERR" | grep -vE '^item: .* ok ' | sed 's/^/    err: /' | head -12
fi

[ "$pass" = "$total" ] && echo "ok:relay-preflight:$pass/$total" || echo "fail:relay-preflight:$pass/$total"
[ "$pass" = "$total" ]
