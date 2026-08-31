#!/usr/bin/env bash
# test-gate-stamp-memoization.sh — fixtures for order 765-tkq2.
# @trace spec:methodology-accountability
#
# Two layers, because the two halves fail differently:
#
#   DECISION  `gate-stamp.sh memo-check` in a throwaway repo — every refusal
#             reason, driven against real stamps. Fast and hermetic.
#   WIRING    the real `./build.sh --check` in this checkout — that the memo
#             is actually consulted, that it is LOUD, that the override and
#             combined dispatches bypass it, and that a RED gate leaves no
#             stamp behind to memoize.
#
# The wiring cases that must NOT memoize would each cost a full multi-minute
# gate to run to completion, so they are bounded: start the gate, assert it
# did NOT take the memo path and DID begin real work, then stop it. What is
# being tested is the branch taken, and that is decided in the first second.
#
# Run: scripts/test-gate-stamp-memoization.sh   (exit 0 = pass)
set -uo pipefail

# Portable SHA-256 (851-28b5): coreutils sha256sum on Linux/forge/WSL; stock
# macOS before 13 ships only `shasum`. Identical "<hex>  <name>" output.
if command -v sha256sum >/dev/null 2>&1; then
    PORTABLE_SHA256=(sha256sum)
else
    PORTABLE_SHA256=(shasum -a 256)
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE_STAMP="$ROOT/scripts/gate-stamp.sh"
fail=0
pass=0

ok()   { echo "ok: $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL: $1" >&2; fail=1; }

# ── DECISION layer ───────────────────────────────────────────────────────────
# A throwaway repo so stamps, edits and toolchain fakes cannot touch the real
# checkout's stamp (which the parent cycle's own pushes depend on).
TDIR="$(mktemp -d)"
trap 'rm -rf "$TDIR"' EXIT

setup_repo() {
    rm -rf "$TDIR/repo"
    mkdir -p "$TDIR/repo/scripts"
    git -C "$TDIR/repo" init -q
    git -C "$TDIR/repo" config user.email fixture@localhost
    git -C "$TDIR/repo" config user.name fixture
    cp "$GATE_STAMP" "$TDIR/repo/scripts/gate-stamp.sh"
    printf 'content\n' > "$TDIR/repo/tracked.txt"
    git -C "$TDIR/repo" add -A
    git -C "$TDIR/repo" commit -qm fixture
}

# ORDER 940-f77j — `write` now requires the one-shot pass token a GREEN gate
# issues. This fixture stands in for the gate (its subject is the memo
# DECISION, not stamp earning), so it issues the token the way build.sh does
# before each write it expects to succeed.
issue_pass_token() {
    local _d
    _d="$(cd "$TDIR/repo" && bash scripts/gate-stamp.sh compute)" || return 1
    {
        echo 'version 1'
        echo "digest $_d"
        echo 'dispatch check'
        echo 'issued now'
    } > "$(git -C "$TDIR/repo" rev-parse --absolute-git-dir)/tillandsias-gate-pass-token"
}

# Prints the verdict and RETURNS the exit code, so callers can use
# `v="$(memo check)"; rc=$?` — a command substitution runs in a subshell, so a
# global assigned inside would never reach the caller (it did not, first try).
memo() { # <dispatch>
    ( cd "$TDIR/repo" && bash scripts/gate-stamp.sh memo-check "$1" 2>&1 )
}

# 1. Unchanged tree after a green stamp -> memo hit carrying the timestamp.
setup_repo
issue_pass_token
(cd "$TDIR/repo" && bash scripts/gate-stamp.sh write --scope full --dispatch check >/dev/null)
v="$(memo check)"; rc=$?
if [ "$rc" -eq 0 ] && [ "${v#ok:gate-fresh }" != "$v" ]; then
    ok "unchanged tree memoizes and reports when it was stamped"
else
    bad "unchanged tree should memoize; got rc=$rc [$v]"
fi

# 2. A changed TRACKED byte invalidates it.
printf 'changed\n' > "$TDIR/repo/tracked.txt"
v="$(memo check)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$v" = "stale:tree-changed-since-gate" ]; then
    ok "an edited tracked byte refuses the memo"
else
    bad "edited tracked byte should refuse; got rc=$rc [$v]"
fi

# 3. A changed UNTRACKED byte invalidates it too — the stamp covers untracked
#    files, and a memo that ignored them would bless an unvalidated tree.
setup_repo
issue_pass_token
(cd "$TDIR/repo" && bash scripts/gate-stamp.sh write --scope full --dispatch check >/dev/null)
printf 'new\n' > "$TDIR/repo/untracked.txt"
v="$(memo check)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$v" = "stale:tree-changed-since-gate" ]; then
    ok "a NEW untracked file refuses the memo"
else
    bad "untracked file should refuse; got rc=$rc [$v]"
fi

# 4. Toolchain change with byte-identical tree -> refuse. Faked by rewriting
#    the recorded digest, which is what a rustc/clippy bump does to it.
setup_repo
issue_pass_token
(cd "$TDIR/repo" && bash scripts/gate-stamp.sh write --scope full --dispatch check >/dev/null)
stampfile="$TDIR/repo/.git/tillandsias-gate-stamp"
sed -i 's/^toolchain .*/toolchain 0000000000000000000000000000000000000000000000000000000000000000/' "$stampfile"
v="$(memo check)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$v" = "stale:toolchain-changed" ]; then
    ok "a toolchain change refuses the memo on an unchanged tree"
else
    bad "toolchain change should refuse; got rc=$rc [$v]"
fi

# 5. A stamp predating 765-tkq2 (no toolchain field) is stale, not "assume
#    unchanged" — the fail-closed migration path.
setup_repo
issue_pass_token
(cd "$TDIR/repo" && bash scripts/gate-stamp.sh write --scope full --dispatch check >/dev/null)
grep -v '^toolchain ' "$stampfile" > "$stampfile.tmp"
mv "$stampfile.tmp" "$stampfile"
v="$(memo check)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$v" = "stale:no-toolchain-recorded" ]; then
    ok "a stamp without a toolchain field refuses the memo"
else
    bad "missing toolchain field should refuse; got rc=$rc [$v]"
fi

# 6. A v1 (legacy bare-digest) stamp refuses.
setup_repo
(cd "$TDIR/repo" && bash scripts/gate-stamp.sh compute > "$stampfile")
v="$(memo check)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$v" = "stale:legacy-stamp-format" ]; then
    ok "a legacy v1 stamp refuses the memo"
else
    bad "legacy stamp should refuse; got rc=$rc [$v]"
fi

# 7. No stamp at all — the state a RED gate leaves, since only a passing gate
#    ever writes one.
setup_repo
v="$(memo check)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$v" = "stale:never-run" ]; then
    ok "no stamp (the state a red gate leaves) refuses the memo"
else
    bad "absent stamp should refuse; got rc=$rc [$v]"
fi

# 8. A SCOPED stamp may not memoize the whole gate.
setup_repo
issue_pass_token
(cd "$TDIR/repo" && bash scripts/gate-stamp.sh write --scope plan-ledger --dispatch check >/dev/null)
v="$(memo check)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$v" = "stale:scoped-stamp-cannot-memoize-full-gate" ]; then
    ok "a scoped stamp cannot memoize the full gate"
else
    bad "scoped stamp should refuse; got rc=$rc [$v]"
fi

# 9. Dispatch equality: a ci-full stamp does not memoize a --check run.
setup_repo
issue_pass_token
(cd "$TDIR/repo" && bash scripts/gate-stamp.sh write --scope full --dispatch ci-full >/dev/null)
v="$(memo check)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$v" = "stale:dispatch-mismatch:ci-full" ]; then
    ok "a ci-full stamp does not memoize a check dispatch"
else
    bad "dispatch mismatch should refuse; got rc=$rc [$v]"
fi

# 10. NEGATIVE CONTROL for the decision layer: after all those refusals, a
#     freshly stamped tree still passes. Without this, "refuse everything"
#     would satisfy cases 2-9.
setup_repo
issue_pass_token
(cd "$TDIR/repo" && bash scripts/gate-stamp.sh write --scope full --dispatch check >/dev/null)
v="$(memo check)"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "NEGATIVE CONTROL — a fresh stamp still memoizes after the refusal cases"
else
    bad "fresh stamp must still memoize; got rc=$rc [$v]"
fi

# ── WIRING layer (the real build.sh in this checkout) ────────────────────────
# Bounded: a run that must NOT memoize is stopped once it has demonstrably
# entered real work. The branch is decided in the first second.
started_real_work() { grep -q 'Checking Rust formatting' "$1"; }
took_memo()         { grep -q 'ok:gate-fresh (stamped' "$1"; }

# 940-f77j applies to the real checkout's writes too: without a token the
# setup writes below silently refuse, no stamp lands, and case 11 falls
# through to a FULL real gate instead of the memo branch it exists to test.
issue_root_pass_token() {
    local _d
    _d="$(cd "$ROOT" && bash scripts/gate-stamp.sh compute)" || return 1
    {
        echo 'version 1'
        echo "digest $_d"
        echo 'dispatch check'
        echo 'issued now'
    } > "$(git -C "$ROOT" rev-parse --absolute-git-dir)/tillandsias-gate-pass-token"
}

# 11. The gate consults the memo and says so, out loud, with the override.
issue_root_pass_token
bash "$ROOT/scripts/gate-stamp.sh" write --scope full --dispatch check >/dev/null 2>&1
TILLANDSIAS_SKIP_VERSION_BUMP=1 "$ROOT/build.sh" --check > "$TDIR/hit.log" 2>&1
hit_rc=$?
if [ "$hit_rc" -eq 0 ] && took_memo "$TDIR/hit.log" && ! started_real_work "$TDIR/hit.log" &&
    grep -q 'TILLANDSIAS_FORCE_CHECK=1 to re-run' "$TDIR/hit.log"; then
    ok "build.sh --check memoizes loudly, names the override, and runs nothing"
else
    bad "memo hit path wrong; rc=$hit_rc"
    tail -3 "$TDIR/hit.log" >&2
fi

# 12. The override bypasses it. Bounded like case 13: under the litmus
#     runner's PATH the forced run re-execs into the tillandsias-builder
#     toolbox, and that entry alone can eat the whole bound before the
#     formatting check ever prints — so a timeout kill (124) while the memo
#     was NOT taken counts as real work, and only an instant memo exit fails.
TILLANDSIAS_SKIP_VERSION_BUMP=1 TILLANDSIAS_FORCE_CHECK=1 timeout 90 "$ROOT/build.sh" --check > "$TDIR/force.log" 2>&1
force_rc=$?
if ! took_memo "$TDIR/force.log" && { started_real_work "$TDIR/force.log" || [ "$force_rc" -eq 124 ]; }; then
    ok "TILLANDSIAS_FORCE_CHECK=1 bypasses the memo and runs the gate"
else
    bad "force override did not bypass the memo"
    tail -3 "$TDIR/force.log" >&2
fi

# 13. A combined dispatch never memoizes — otherwise `--check --install` would
#     skip the checks AND the install.
#
#     Note the assertion is NOT "it reached the formatting check": build.sh's
#     install block runs BEFORE the check block, so a bounded run spends its
#     budget compiling and never gets there (that cost me a false failure the
#     first time). What must be true is that the memo was not taken and the
#     process was doing real work when the bound hit — an instant exit 0 is
#     the failure being excluded.
TILLANDSIAS_SKIP_VERSION_BUMP=1 timeout 40 "$ROOT/build.sh" --check --install > "$TDIR/combined.log" 2>&1
combined_rc=$?
if ! took_memo "$TDIR/combined.log" && [ "$combined_rc" -eq 124 ]; then
    ok "a combined dispatch (--check --install) never memoizes and does real work"
else
    bad "combined dispatch: memo_taken=$(took_memo "$TDIR/combined.log" && echo yes || echo no) rc=$combined_rc (want 124=still working)"
    tail -3 "$TDIR/combined.log" >&2
fi

# 14. THE CRITICAL ONE: a RED gate must leave no stamp for a later run to
#     memoize. Break formatting (the first check), confirm the gate fails, and
#     confirm the recorded stamp is byte-identical to before.
#     The break must land in a file the toolchain actually READS. A new .rs
#     file no module declares is invisible to `cargo fmt --check --all`, so the
#     first attempt at this case produced a GREEN gate and a false failure —
#     which is itself the lesson: an injected defect that the checker cannot
#     see proves nothing. Appending to an already-compiled file is seen.
STAMP_PATH="$(git -C "$ROOT" rev-parse --absolute-git-dir)/tillandsias-gate-stamp"
VICTIM="crates/tillandsias-vault-client/src/error.rs"
issue_root_pass_token
bash "$ROOT/scripts/gate-stamp.sh" write --scope full --dispatch check >/dev/null 2>&1
before="$("${PORTABLE_SHA256[@]}" "$STAMP_PATH" | cut -d' ' -f1)"
printf 'pub fn   memo_fixture_badfmt( )->u8{1}\n' >> "$ROOT/$VICTIM"
TILLANDSIAS_SKIP_VERSION_BUMP=1 TILLANDSIAS_FORCE_CHECK=1 timeout 300 "$ROOT/build.sh" --check > "$TDIR/red.log" 2>&1
red_rc=$?
git -C "$ROOT" checkout -- "$VICTIM"
after="$("${PORTABLE_SHA256[@]}" "$STAMP_PATH" | cut -d' ' -f1)"
if [ "$red_rc" -ne 0 ] && [ "$before" = "$after" ]; then
    ok "a RED gate writes no stamp, so nothing can memoize it as green"
else
    bad "red gate rc=$red_rc; stamp changed=$([ "$before" = "$after" ] && echo no || echo YES)"
    tail -3 "$TDIR/red.log" >&2
fi

# Leave the checkout's stamp matching reality: the tree changed during case 14.
issue_root_pass_token
bash "$ROOT/scripts/gate-stamp.sh" write --scope full --dispatch check >/dev/null 2>&1

if [ "$fail" -eq 0 ]; then
    echo "ok:gate-stamp-memoization-fixture:$pass"
    exit 0
fi
echo "fail: gate-stamp-memoization fixture had failures" >&2
exit 1
