#!/usr/bin/env bash
# test-plan-only-lane-structural.sh — fixture for order 1152-y3bv.
#
# THE PACKET. Three floor hosts were refused the plan-only lane in one night
# for STRUCTURAL reasons, not tooling gaps: macneo's one-line ledger claim
# was refused because the mandated origin/linux-next merge pulled a non-plan
# path into the outgoing diff that trunk had ALREADY gated (668-2xeh's lane
# judged the whole diff, not what was actually this push's to vouch for);
# pirria's plan-only push was refused as "the resolved plan binary is STALE"
# because the mtime check (1129-4su6, scripts/plan-binary-probe.sh's
# plan_binary_is_stale) compares against the WHOLE crates/tillandsias-plan
# tree and the WHOLE workspace Cargo.lock — esme measured 2026-09-14 that ANY
# Cargo.lock change anywhere in the fifteen-crate workspace re-arms it, three
# ~2m22s rebuilds in one cycle, none of which touched a byte the lane's own
# validation reads.
#
# THIS FIXTURE PINS BOTH FIXES:
#   (a) a non-plan path in the outgoing diff whose PUSHED BLOB is
#       byte-identical to origin/linux-next's blob for that path is dropped,
#       not refused (scripts/hooks/pre-push-local-gate.sh's catch-all `*)`
#       arm, order 1152-y3bv).
#   (b) NEGATIVE: a non-plan path that DIFFERS from origin/linux-next still
#       forces the full gate.
#   (c) plan-only staleness is judged against the VALIDATOR SURFACE — a
#       hash of the sources implementing validate-yaml, check
#       --strict-fragments and the fragment checkers, recorded beside the
#       binary by scripts/check-plan-binary-current.sh at the moment it
#       independently confirms (via the OLD, broader mtime check) that the
#       binary is current — so a change elsewhere in the crate or workspace
#       lock does not re-arm it.
#   (d) NEGATIVE: a change to the validator surface's OWN sources still
#       refuses a stale binary, and the remedy names the exact rebuild.
#
# EACH ARM CARRIES A MUTATION CONTROL, built by STRIPPING the exact construct
# from a COPY of the file it lives in (never by picking an old git revision —
# a git-provenance "before" can drift out of sync with what this fixture
# actually asserts). `cmp` proves the strip changed real bytes, so a future
# refactor that moves the construct fails LOUDLY here instead of silently
# turning every mutation arm into a no-op that always "passes".
#
# HERMETIC: two scratch git repos (a bare "remote" plus a working copy each),
# a stub tillandsias-plan binary, a stub for check-plan-binary-current.sh's
# OWN fixture dependency (test-expire-claims-write-is-opt-in.sh — a different
# packet's 16-arm write-vs-read behaviour has nothing to do with this one),
# mktemp only. No network, no credentials, the real repo is never touched.
#
# SEAMS REUSED FROM THE ESTABLISHED FIXTURES, not invented here:
#   - the bare-remote + working-copy + `core.hooksPath` + piped-refs harness
#     is scripts/test-pre-push-plan-lane-after-merge.sh's (arms a/b: a
#     non-plan path must be judged against a DIFFERENT ref than the push
#     target, or the defect cannot even be constructed — that fixture's own
#     header explains why a same-branch repro proves nothing).
#   - the crate-tree + stub-binary + mtime-controlled staleness harness is
#     scripts/test-plan-binary-freshness.sh's (arms c/d), with one change:
#     that fixture's main.rs is deliberately `fn main() {}` so it always
#     falls to the mtime fallback; this fixture's main.rs deliberately
#     CONTAINS the grep keywords so it exercises the new validator-surface
#     path instead.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/hooks/pre-push-local-gate.sh"
CHECKER="$ROOT/scripts/check-plan-binary-current.sh"

pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/plan-lane-structural.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM
export GIT_TERMINAL_PROMPT=0

# ── Mutated copies of the two owned files, one per construct under test ────
# Built ONCE, from CONTENT (a `sed` strip against the real file), never from
# git history. Each is verified non-vacuous (cmp against the original) before
# any arm trusts it.
MUT_A="$WORK/mut-a-drop-blob-carveout.sh"
MUT_B="$WORK/mut-b-weaken-equality.sh"
MUT_C="$WORK/mut-c-revert-to-mtime.sh"
MUT_D="$WORK/mut-d-surface-stale-reads-fresh.sh"

# MUTATION A: delete the whole byte-identical-to-trunk carve-out, restoring
# the pre-1152-y3bv unconditional refusal for every non-plan path.
sed '/# ORDER 1152-y3bv\. A non-plan path is not automatically/,/^                    fi$/d' \
    "$GUARD" > "$MUT_A"
# MUTATION B: keep the carve-out's SHAPE but drop the content-equality test,
# so ANY non-plan path that exists at all on trunk gets dropped regardless of
# whether its bytes actually match — the over-broad bug this arm exists to
# catch.
sed 's/if \[\[ -n "\$_1152_push_blob" && "\$_1152_trunk_blob" == "\$_1152_push_blob" \]\]; then/if [[ -n "$_1152_trunk_blob" ]]; then/' \
    "$GUARD" > "$MUT_B"
# MUTATION C: revert the lane's staleness predicate to the bare pre-1152-y3bv
# mtime check, dropping the validator-surface consultation entirely.
sed 's/&& _lane_staleness_check "\$plan_bin"; then/\&\& plan_binary_is_stale "$plan_bin"; then/' \
    "$GUARD" > "$MUT_C"
# MUTATION D: keep the validator-surface machinery but make the "differs"
# verdict (case arm `1)`) report FRESH instead of STALE — the shape of bug
# that would silently readmit a changed validator.
sed "\\#validate-yaml/check --strict-fragments/the fragment checkers' own sources changed#{n;s#return 0#return 1#}" \
    "$GUARD" > "$MUT_D"

for _mp in "MUT_A:$MUT_A" "MUT_B:$MUT_B" "MUT_C:$MUT_C" "MUT_D:$MUT_D"; do
    _mname="${_mp%%:*}"; _mfile="${_mp#*:}"
    if cmp -s "$GUARD" "$_mfile"; then
        bad "MUTATION SETUP $_mname is a NO-OP strip — the sed pattern no longer matches scripts/hooks/pre-push-local-gate.sh; this mutation's arm proves nothing until the pattern is updated"
    elif ! bash -n "$_mfile" 2>/dev/null; then
        bad "MUTATION SETUP $_mname produced a syntactically broken script"
    else
        ok "MUTATION SETUP $_mname: cmp confirms a real strip, and it still parses"
    fi
done

# ════════════════════════════════════════════════════════════════════════
# ARMS A / B — PATH CLASSIFICATION (deliverable 1)
# ════════════════════════════════════════════════════════════════════════
# Cross-branch, deliberately (see header): the push target's remote must be a
# DIFFERENT ref than origin/linux-next, or a path that trunk already carries
# can never differ from the push's own remote in the first place and the
# defect this arm exists to catch cannot be constructed.
AB="$WORK/ab"
mkdir -p "$AB"
git init -q --bare "$AB/bare.git"
git init -q -b linux-next "$AB/wc"
( cd "$AB/wc" && git remote add origin "$AB/bare.git" \
      && git config core.hooksPath .git/hooks && git config core.autocrlf false )
GA() { git -C "$AB/wc" -c user.email=t@t -c user.name=t "$@"; }

mkdir -p "$AB/wc/scripts/hooks" "$AB/wc/plan/index.d"
cp "$GUARD" "$AB/wc/scripts/hooks/pre-push-local-gate.sh"
for f in plan-binary-probe.sh gate-stamp.sh common.sh check-issue-citation-convention.sh; do
    cp "$ROOT/scripts/$f" "$AB/wc/scripts/$f" 2>/dev/null || true
done
chmod +x "$AB/wc/scripts"/*.sh "$AB/wc/scripts/hooks"/*.sh 2>/dev/null || true

# ORDER 1109-t8kw, predicate (d) — A TOOL ASSUMED PRESENT.
#
# Arms A-D need the plan-only lane to be APPLICABLE, and the lane fails closed
# unless it can validate fragments: pre-push-local-gate.sh:1003 requires `yq` on
# PATH *or* a runnable target/release/tillandsias-plan. This scratch worktree is
# built from scratch, so it has no target/release, and run_guard_ab deliberately
# unsets TILLANDSIAS_PLAN_BIN to exercise the real discovery path. On a host with
# yq that gap is invisible — yq satisfies the check and all four arms run. On a
# host WITHOUT yq there is no validator at all, the lane correctly refuses with
# "neither yq nor target/release/tillandsias-plan is available to validate
# fragments (fail closed; full gate required)", and this fixture scored that
# CORRECT REFUSAL as arm A failing. That is this packet's title exactly: a
# fixture asserting a property of the environment it runs in, so a correct
# refusal reads as a failure.
#
# MEASURED on pirria 2026-09-14 (Linux floor, no yq, unprovisionable here —
# the toolbox route is Silverblue-only): 12/14 with arms A and B red, and
# 14/14 from the same tree with one line seeding the binary below. The guard
# was right both times; only the fixture's environment changed.
#
# So CONSTRUCT the property rather than inherit it. If this checkout has no
# built binary either, SKIP BY NAME rather than scoring the guard wrong for an
# environment the arm never claimed to need — the precedent is
# test-claims-across-branches.sh's own 1109-t8kw skip.
#
# AND IT IS THE BINARY, NOT yq. `yq` satisfies the lane's FIRST validator gate
# (pre-push-local-gate.sh:1003) and is NOT enough for these arms: arm A's push
# adds a plan/index.d fragment, so the lane also runs the fold and status-loss
# checks, and those refuse with "no runnable tillandsias-plan resolved" —
# "yq validates one blob's shape; it cannot fold the ledger, which is what
# these two checks read" (1124-7f3u, quoted from the guard's own remedy line).
# A first version of this fix treated yq as sufficient and skipped the copy;
# it passed on this yq-absent host and still failed under the litmus runner,
# which is what surfaced the distinction. Construct the binary unconditionally.
AB_VALIDATOR=1
if [ -x "$ROOT/target/release/tillandsias-plan" ]; then
    mkdir -p "$AB/wc/target/release"
    cp "$ROOT/target/release/tillandsias-plan" "$AB/wc/target/release/tillandsias-plan"
else
    AB_VALIDATOR=0
fi

printf 'packets: []\n' > "$AB/wc/plan/index.yaml"
printf 'trunk-version-old\n' > "$AB/wc/shared.txt"
GA add -A >/dev/null; GA commit -q -m base
GA push -q -u origin linux-next
GA push -q origin linux-next:windows-next

# Trunk moves independently, on linux-next, while the checkout is still on it.
printf 'trunk-version-new\n' > "$AB/wc/shared.txt"
GA add -A >/dev/null; GA commit -q -m "trunk moves shared.txt"
GA push -q origin linux-next
# Now board windows-next at its OLD base — the push branch has not seen
# trunk's change yet, which is exactly what makes shared.txt show up in the
# NEXT commit's outgoing diff against origin/windows-next.
GA checkout -q -B windows-next origin/windows-next

run_guard_ab() {
    ( cd "$AB/wc" && env -u TILLANDSIAS_PLAN_BIN -u CARGO_TARGET_DIR \
        bash scripts/hooks/pre-push-local-gate.sh 2>&1 <<< \
        "refs/heads/windows-next $(git rev-parse HEAD) refs/heads/windows-next $(git rev-parse origin/windows-next)" )
}
run_guard_ab_with() { # $1 = alternate hook script (absolute path)
    local save="$AB/wc/scripts/hooks/pre-push-local-gate.sh.swap"
    cp "$AB/wc/scripts/hooks/pre-push-local-gate.sh" "$save"
    cp "$1" "$AB/wc/scripts/hooks/pre-push-local-gate.sh"
    chmod +x "$AB/wc/scripts/hooks/pre-push-local-gate.sh"
    local out rc
    out="$(run_guard_ab)"; rc=$?
    cp "$save" "$AB/wc/scripts/hooks/pre-push-local-gate.sh"
    rm -f "$save"
    printf '%s\nGUARDRC=%d\n' "$out" "$rc"
}
reset_ab() { GA reset -q --hard origin/windows-next; git -C "$AB/wc" clean -qfd; mkdir -p "$AB/wc/plan/index.d"; }

if [ "$AB_VALIDATOR" -eq 0 ]; then
    echo "skip:arms-ab:no-plan-binary (1109-t8kw) — target/release/tillandsias-plan is not built in this checkout, so the lane's fold and status-loss precondition cannot be constructed (yq does not substitute, 1124-7f3u); NOT a verdict about the guard"
else
# ── ARM A: a non-plan path byte-identical to origin/linux-next is dropped ──
printf 'packets: []\n' > "$AB/wc/plan/index.d/20260913t000000z-arm-a.yaml"
printf 'trunk-version-new\n' > "$AB/wc/shared.txt"   # matches trunk's NEW content exactly
GA add -A >/dev/null; GA commit -q -m "own commit whose non-plan path happens to match trunk"
_outgoing="$(GA diff --name-only origin/windows-next HEAD)"
case "$_outgoing" in
    *shared.txt*) ;;
    *) bad "ARM A is VACUOUS — shared.txt is not in the outgoing diff" ;;
esac
out="$(run_guard_ab)"; rc=$?
case "$rc:$out" in
    0:*"byte-identical to origin/linux-next"*)
        ok "ARM A: a non-plan path byte-identical to origin/linux-next is dropped, not refused (pre-fix result: FAILS — macneo 2026-09-13)" ;;
    *)
        bad "ARM A: the lane refused (or did not name the carve-out for) a non-plan path matching trunk (rc=$rc)"
        printf '%s\n' "$out" | sed 's/^/      /' >&2 ;;
esac

out="$(run_guard_ab_with "$MUT_A")"
rc="$(printf '%s' "$out" | sed -n 's/^GUARDRC=//p')"
if [ "$rc" != "0" ]; then
    ok "MUTATION A: stripping the carve-out makes arm A's own push wrongly refused (arm A has teeth)"
else
    bad "MUTATION A: arm A's scenario still passes with the carve-out stripped — arm A proves nothing"
fi
reset_ab

# ── ARM B: NEGATIVE — a non-plan path that DIFFERS from trunk still refuses ─
printf 'packets: []\n' > "$AB/wc/plan/index.d/20260913t000001z-arm-b.yaml"
printf 'windows-own-version\n' > "$AB/wc/shared.txt"   # DIFFERS from trunk's new content
GA add -A >/dev/null; GA commit -q -m "own commit whose non-plan path diverges from trunk"
_outgoing="$(GA diff --name-only origin/windows-next HEAD)"
case "$_outgoing" in
    *shared.txt*) ;;
    *) bad "ARM B is VACUOUS — shared.txt is not in the outgoing diff" ;;
esac
out="$(run_guard_ab)"; rc=$?
case "$rc:$out" in
    0:*) bad "ARM B: a non-plan path diverging from trunk was NOT refused by the path-scope rule — BYPASS (rc=$rc)"
         printf '%s\n' "$out" | sed 's/^/      /' >&2 ;;
    *:*"differs from origin/linux-next"*)
        ok "ARM B (NEGATIVE): a non-plan path differing from origin/linux-next still forces the full gate" ;;
    *)
        bad "ARM B: refused, but not by the path-scope rule (rc=$rc)"
        printf '%s\n' "$out" | sed 's/^/      /' >&2 ;;
esac

out="$(run_guard_ab_with "$MUT_B")"
rc="$(printf '%s' "$out" | sed -n 's/^GUARDRC=//p')"
if [ "$rc" = "0" ]; then
    ok "MUTATION B: weakening the equality test to plain existence-on-trunk makes arm B's own push wrongly ACCEPTED (arm B has teeth)"
else
    bad "MUTATION B: arm B's scenario still refuses with the equality test weakened — arm B proves nothing"
fi
reset_ab
fi   # AB_VALIDATOR (1109-t8kw skip-by-name)

# ════════════════════════════════════════════════════════════════════════
# ARMS C / D — STALENESS AGAINST THE VALIDATOR SURFACE (deliverable 2)
# ════════════════════════════════════════════════════════════════════════
CD="$WORK/cd"
mkdir -p "$CD"
git init -q --bare "$CD/bare.git"
git init -q -b linux-next "$CD/wc"
( cd "$CD/wc" && git remote add origin "$CD/bare.git" \
      && git config core.hooksPath .git/hooks && git config core.autocrlf false )
GC() { git -C "$CD/wc" -c user.email=t@t -c user.name=t "$@"; }

mkdir -p "$CD/wc/scripts/hooks" "$CD/wc/plan/index.d" "$CD/wc/target/release" \
         "$CD/wc/crates/tillandsias-plan/src"
cp "$GUARD" "$CD/wc/scripts/hooks/pre-push-local-gate.sh"
cp "$CHECKER" "$CD/wc/scripts/check-plan-binary-current.sh"
for f in plan-binary-probe.sh gate-stamp.sh common.sh check-issue-citation-convention.sh check-fragment-status-loss.sh; do
    cp "$ROOT/scripts/$f" "$CD/wc/scripts/$f" 2>/dev/null || true
done
# A trivial stand-in for check-plan-binary-current.sh's OWN fixture
# dependency. That fixture's 16 write-vs-read arms are order 1079-qb8k's
# concern, unrelated to this packet; this stub exists only so
# check-plan-binary-current.sh reaches the validator-surface stamping code
# this packet adds, which runs BEFORE it shells out to that fixture.
cat > "$CD/wc/scripts/test-expire-claims-write-is-opt-in.sh" <<'STUB'
#!/usr/bin/env bash
echo "expire-claims-write-is-opt-in: 0 passed, 0 failed"
exit 0
STUB
chmod +x "$CD/wc/scripts"/*.sh "$CD/wc/scripts/hooks"/*.sh 2>/dev/null || true

# A REAL validator-surface source: unlike test-plan-binary-freshness.sh's
# deliberately-inert `fn main() {}` (which exercises the mtime FALLBACK),
# this one contains the four keywords 1152-y3bv's fix greps for, so these
# arms exercise the validator-surface path itself.
cat > "$CD/wc/crates/tillandsias-plan/src/main.rs" <<'RS'
fn main() {
    // implements validate-yaml, strict-fragments, declared-closures-check,
    // and closure-evidence-check for this fixture's grep to find.
}
RS
cat > "$CD/wc/crates/tillandsias-plan/Cargo.toml" <<'TOML'
[package]
name = "tillandsias-plan"
version = "0.1.0"
TOML
printf '# lock\n' > "$CD/wc/Cargo.lock"
# A second crate source file that does NOT match the grep — "elsewhere in
# the crate" for arm C.
printf 'fn other() {}\n' > "$CD/wc/crates/tillandsias-plan/src/other_subcommand.rs"

cat > "$CD/wc/target/release/tillandsias-plan" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    capabilities) echo compact; exit 0 ;;
    build-id) echo "0.1.0+deadbeef"; exit 0 ;;
    check) exit 0 ;;
    validate-yaml) exit 0 ;;
    yaml-type) echo '!!map'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$CD/wc/target/release/tillandsias-plan"

printf '/target/\n' > "$CD/wc/.gitignore"
printf 'packets: []\n' > "$CD/wc/plan/index.yaml"
GC add -A >/dev/null; GC commit -q -m base
GC push -q -u origin linux-next

# Mint the validator-surface stamp with the REAL, owned check-plan-binary-current.sh
# — not a hand-written stand-in for it. Its own write-is-opt-in verdict is
# irrelevant here (the stub fixture above answers 0/0 either way); only the
# stamp file matters, and it is written before that verdict is even reached.
( cd "$CD/wc" && env -u TILLANDSIAS_PLAN_BIN -u TILLANDSIAS_PLAN_BINARY -u CARGO_TARGET_DIR \
    bash scripts/check-plan-binary-current.sh ) >/dev/null 2>&1 || true
STAMP="$CD/wc/target/release/tillandsias-plan.validator-surface-sha256"
if [ -s "$STAMP" ]; then
    ok "SETUP: scripts/check-plan-binary-current.sh minted the validator-surface stamp"
else
    bad "SETUP: no validator-surface stamp was minted — arms C/D cannot run"
fi

# ── Cross-check: the two owned copies of the hash computation agree ────────
# 1152-y3bv duplicates the validator-surface hash in both owned files rather
# than sharing it (no library file is in this packet's scope). Checked HERE,
# before arm C/D touch any crate file, while the sources the writer just
# hashed are still exactly the sources on disk — if the two ever drift, this
# is where it is caught, before it caused one side to mis-score the other's
# stamp.
READER_HASH=""
( cd "$CD/wc"
  # shellcheck disable=SC1090
  eval "$(sed -n '/^_validator_surface_files() {/,/^attempt_plan_only_lane() {/p' "$GUARD" | sed '$d')"
  _validator_surface_hash
) > "$WORK/reader-hash.txt" 2>/dev/null
READER_HASH="$(cat "$WORK/reader-hash.txt" 2>/dev/null)"
WRITER_HASH="$(cat "$STAMP" 2>/dev/null)"
if [ -n "$READER_HASH" ] && [ "$READER_HASH" = "$WRITER_HASH" ]; then
    ok "CROSS-CHECK: the reader's (pre-push-local-gate.sh) and writer's (check-plan-binary-current.sh) validator-surface hashes agree"
else
    bad "CROSS-CHECK: the two owned copies of the validator-surface hash computation DISAGREE (reader='$READER_HASH' writer='$WRITER_HASH')"
fi

run_guard_cd() {
    ( cd "$CD/wc" && env -u TILLANDSIAS_PLAN_BIN -u CARGO_TARGET_DIR \
        bash scripts/hooks/pre-push-local-gate.sh 2>&1 <<< \
        "refs/heads/linux-next $(git rev-parse HEAD) refs/heads/linux-next $(git rev-parse origin/linux-next)" )
}
run_guard_cd_with() { # $1 = alternate hook script (absolute path)
    local save="$CD/wc/scripts/hooks/pre-push-local-gate.sh.swap"
    cp "$CD/wc/scripts/hooks/pre-push-local-gate.sh" "$save"
    cp "$1" "$CD/wc/scripts/hooks/pre-push-local-gate.sh"
    chmod +x "$CD/wc/scripts/hooks/pre-push-local-gate.sh"
    local out rc
    out="$(run_guard_cd)"; rc=$?
    cp "$save" "$CD/wc/scripts/hooks/pre-push-local-gate.sh"
    rm -f "$save"
    printf '%s\nGUARDRC=%d\n' "$out" "$rc"
}

# ── ARM C: a change elsewhere in the crate leaves the surface unstaled ─────
# other_subcommand.rs and Cargo.lock are touched ON DISK ONLY — never
# committed — so the outgoing diff this push carries is the fragment alone;
# the mtime bump is what would have re-armed the OLD check (esme's exact
# measured shape: an unrelated workspace change re-arms 1129-4su6's mtime
# test), and this arm proves the validator-surface hash does not move for it.
touch "$CD/wc/crates/tillandsias-plan/src/other_subcommand.rs"
touch "$CD/wc/Cargo.lock"
_mtime_verdict="unknown"
( . "$ROOT/scripts/plan-binary-probe.sh"
  cd "$CD/wc" || exit 2
  if plan_binary_is_stale ./target/release/tillandsias-plan; then exit 0; else exit 1; fi
)
case $? in
    0) _mtime_verdict="stale" ;;
    1) _mtime_verdict="fresh" ;;
esac
if [ "$_mtime_verdict" != "stale" ]; then
    bad "ARM C is VACUOUS — the OLD mtime check does not even consider this binary stale, so this arm cannot show the fix changing anything (pre-fix result should be FAILS, got: $_mtime_verdict)"
fi
printf 'packets: []\n' > "$CD/wc/plan/index.d/20260913t000002z-arm-c.yaml"
GC add plan/index.d/20260913t000002z-arm-c.yaml >/dev/null
GC commit -q -m "just a fragment; the crate/lock touch above never entered a commit"
_outgoing="$(GC diff --name-only origin/linux-next HEAD)"
case "$_outgoing" in
    *"other_subcommand.rs"*|*"Cargo.lock"*)
        bad "ARM C's own scaffolding leaked the crate/lock touch into the outgoing diff — the arm no longer tests staleness in isolation" ;;
esac
out="$(run_guard_cd)"; rc=$?
case "$rc:$out" in
    0:*"is STALE"*)
        bad "ARM C: the lane accepted (rc=0) but still printed an 'is STALE' line — investigate"
        printf '%s\n' "$out" | sed 's/^/      /' >&2 ;;
    0:*)
        ok "ARM C: a change elsewhere in the crate (surface hash unchanged) does not stale the lane (pre-fix result: FAILS — mtime says stale)" ;;
    *)
        bad "ARM C: an unrelated crate/lock change wrongly staled the plan-only lane (rc=$rc)"
        printf '%s\n' "$out" | sed 's/^/      /' >&2 ;;
esac

out="$(run_guard_cd_with "$MUT_C")"
rc="$(printf '%s' "$out" | sed -n 's/^GUARDRC=//p')"
if [ "$rc" != "0" ]; then
    ok "MUTATION C: reverting to the bare mtime predicate makes arm C's own push wrongly refused (arm C has teeth)"
else
    bad "MUTATION C: arm C's scenario still passes with the surface check reverted to mtime — arm C proves nothing"
fi

# ── ARM D: NEGATIVE — a validator-surface source change still refuses ──────
cat > "$CD/wc/crates/tillandsias-plan/src/main.rs" <<'RS'
fn main() {
    // implements validate-yaml, strict-fragments, declared-closures-check,
    // and closure-evidence-check for this fixture's grep to find.
    // CHANGED for arm D — the validator's own sources moved.
}
RS
printf 'packets: []\n' > "$CD/wc/plan/index.d/20260913t000003z-arm-d.yaml"
GC add plan/index.d/20260913t000003z-arm-d.yaml >/dev/null
GC commit -q -m "just a fragment; main.rs changed on disk, never committed"
_outgoing="$(GC diff --name-only origin/linux-next HEAD)"
case "$_outgoing" in
    *"main.rs"*)
        bad "ARM D's own scaffolding leaked the main.rs edit into the outgoing diff — the arm no longer tests staleness in isolation" ;;
esac
out="$(run_guard_cd)"; rc=$?
case "$rc:$out" in
    0:*)
        bad "ARM D: a real validator-surface change was NOT refused — BYPASS (rc=$rc)"
        printf '%s\n' "$out" | sed 's/^/      /' >&2 ;;
    *:*"validator-surface hash"*"cargo build --release -p tillandsias-plan && bash scripts/check-plan-binary-current.sh"*)
        ok "ARM D (NEGATIVE): a validator-surface source change still refuses a stale binary, and the remedy names the exact rebuild command" ;;
    *)
        bad "ARM D: a real validator-surface change was refused, but did not name the exact remedy (rc=$rc)"
        printf '%s\n' "$out" | sed 's/^/      /' >&2 ;;
esac

out="$(run_guard_cd_with "$MUT_D")"
rc="$(printf '%s' "$out" | sed -n 's/^GUARDRC=//p')"
if [ "$rc" = "0" ]; then
    ok "MUTATION D: making the surface-differs verdict report fresh makes arm D's own push wrongly ACCEPTED (arm D has teeth)"
else
    bad "MUTATION D: arm D's scenario still refuses with the surface-differs verdict inverted — arm D proves nothing"
fi

echo "plan-only-lane-structural: $pass passed, $fail failed"
if [ "$fail" -eq 0 ]; then
    echo "PASS: plan-only-lane-structural $pass/$pass (1152-y3bv)"
    exit 0
fi
echo "FAIL: plan-only-lane-structural $pass/$((pass + fail)) (1152-y3bv)"
exit 1
