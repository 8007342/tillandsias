#!/usr/bin/env bash
# @trace order:877-mynm, order:863-iicc
#
# test-pre-push-empty-ref-list.sh — pin what an EMPTY pre-push ref list means,
# and pin that the local gate stops paying a full gate for a push git has
# already decided not to send.
#
# THE FINDING THIS EXISTS TO PROTECT. pre-push-local-gate.sh reported
# "plan-only lane: not applicable — no ref list on stdin" and then refused with
# "the tree changed since ./build.sh --check last passed". Both lines were true.
# The conclusion was wrong, because nobody had decoded the empty list: git hands
# the hook no refs exactly when it is sending no refs. The reader was told to
# run the gate (~90s on the floor host) when the real remedy was `git pull
# --rebase`, for a push that could not happen either way.
#
# The five arms below are the measurement that established that, kept
# executable so the claim cannot rot into a comment. Arm 5 is the one that
# matters most: a STALE remote-tracking ref still yields a ref list, so the
# emptiness is specifically "git already knows", not "non-fast-forward".
#
# Hermetic: local bare remote, no network, no credentials, real composed-hook
# shape (capture once, replay to each guard). Scratch tree removed on exit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/hooks/pre-push-local-gate.sh"
fail=0; pass=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/prepush-refs-test.XXXXXX")"
trap 'restore_ambient_stamp; rm -rf "$W"' EXIT INT TERM
export GIT_TERMINAL_PROMPT=0
G() { git -c user.email=t@t -c user.name=t "$@"; }

# ── AMBIENT STAMP CONTROL (877-mynm follow-up; diagnosed by yoga 2026-08-26) ──
# Arms 7 and 8 invoke the real guard so that it runs against a REAL tillandsias
# checkout — that is deliberate and necessary: in a hermetic scratch repo the
# guard finds no gate machinery, takes its nothing-to-gate path and accepts
# everything, so the arms would assert nothing. What was NOT deliberate is that
# the guard then reads THIS checkout's .git/tillandsias-gate-stamp, whose
# presence varies with what the host did last.
#
# That made the fixture BISTABLE, and through it the gate. The gate writes its
# stamp at the END of a run, so:
#   no valid stamp -> arms pass -> ./build.sh --check GREEN -> stamp written
#   next run       -> stamp exists -> arms fail -> RED -> no stamp written
#   next run       -> no stamp -> GREEN ...
# `./build.sh --check` alternated green/red on an UNCHANGED tree, and "re-run
# it and see" returned whichever answer the parity landed on. Latent from
# 292ff7607 until a release night ran the gate twice in a row on a clean tree.
#
# The fix is to make the variable a CONSTANT rather than to hide from it: hold
# the stamp aside for the duration of the arms that depend on its absence, and
# restore it on every exit path. Isolating the guard into the scratch repo was
# tried first and is wrong — it removes the very thing the arms measure.
AMBIENT_STAMP="$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null)/tillandsias-gate-stamp"
STAMP_HELD=""
hold_ambient_stamp() {
    if [ -f "$AMBIENT_STAMP" ]; then
        STAMP_HELD="$W/ambient-gate-stamp.held"
        cp -p "$AMBIENT_STAMP" "$STAMP_HELD" && rm -f "$AMBIENT_STAMP"
    fi
}
restore_ambient_stamp() {
    [ -n "$STAMP_HELD" ] && [ -f "$STAMP_HELD" ] || return 0
    cp -p "$STAMP_HELD" "$AMBIENT_STAMP"; STAMP_HELD=""
}

git init -q --bare "$W/bare.git"
git init -q -b linux-next "$W/wc"; ( cd "$W/wc" && git remote add origin "$W/bare.git" )
git init -q -b linux-next "$W/other"; ( cd "$W/other" && git remote add origin "$W/bare.git" )

# core.hooksPath is GLOBAL and OVERRIDES .git/hooks — pin it per scratch repo.
# A forge provisions core.hooksPath=~/.cache/tillandsias/git-hooks in
# ~/.gitconfig, and git's rule is that a set core.hooksPath replaces the
# per-repo hooks directory outright. install_spy below writes to .git/hooks,
# so in a forge the spy was NEVER INVOKED: every arm that measures git's ref
# list read an empty capture and reported '<none>', reddening ./build.sh
# --check on every forge on the fleet while arms 6-11 (which pipe stdin to the
# guard directly and never go through git) stayed green. The failure looked
# like the ref-list behaviour had changed; it was the fixture never observing
# it. Setting it LOCALLY here restores the documented default without touching
# the ambient config, which the surrounding arms deliberately leave alone.
( cd "$W/wc" && git config core.hooksPath .git/hooks )
( cd "$W/other" && git config core.hooksPath .git/hooks )

# A spy in the composed hook's exact shape: capture stdin once, report its size.
install_spy() {
    cat > "$1/.git/hooks/pre-push" <<'SPY'
#!/usr/bin/env bash
REFS="$(cat)"
echo "REFBYTES=${#REFS}" >&2
exit 1
SPY
    chmod +x "$1/.git/hooks/pre-push"
}
refbytes() { ( cd "$1"; shift; git push "$@" 2>&1 | sed -n 's/^REFBYTES=//p' | head -1 ); }

( cd "$W/wc" && G commit -q --allow-empty -m base && git push -q -u origin linux-next )
install_spy "$W/wc"

# ── 1. A fast-forward push carries a ref list. ─────────────────────────────
( cd "$W/wc" && G commit -q --allow-empty -m ff )
b="$(refbytes "$W/wc" origin linux-next)"
[ "${b:-0}" -gt 0 ] && ok "fast-forward push carries a ref list ($b bytes)" \
    || bad "fast-forward push had no ref list (got '${b:-<none>}')"

# ── 2. `--dry-run origin HEAD` — the credential guard's probe form — too. ──
b="$(refbytes "$W/wc" --dry-run origin HEAD)"
[ "${b:-0}" -gt 0 ] && ok "the --dry-run origin HEAD probe form carries a ref list ($b bytes)" \
    || bad "the credential probe form had no ref list (got '${b:-<none>}')"

# ── 3. Already up to date -> EMPTY. Nothing is being sent. ─────────────────
( cd "$W/wc" && git push -q --no-verify origin linux-next )
b="$(refbytes "$W/wc" origin linux-next)"
[ "${b:-x}" = "0" ] && ok "an up-to-date push yields an EMPTY ref list" \
    || bad "up-to-date push — want 0 bytes, got '${b:-<none>}'"

# ── 4. Non-fast-forward with a CURRENT remote-tracking ref -> EMPTY. ───────
#      This is the case that cost a full gate on every lost claim race.
( cd "$W/other" && git fetch -q origin && git reset -q --hard origin/linux-next \
    && G commit -q --allow-empty -m "other host" && git push -q origin linux-next )
( cd "$W/wc" && G commit -q --allow-empty -m mine && git fetch -q origin )
b="$(refbytes "$W/wc" origin linux-next)"
[ "${b:-x}" = "0" ] && ok "non-ff with a CURRENT remote-tracking ref yields an EMPTY ref list" \
    || bad "non-ff/current — want 0 bytes, got '${b:-<none>}'"

# ── 5. THE DISCRIMINATOR: non-ff with a STALE remote-tracking ref is NOT ───
#      empty. So emptiness means "git already knows", not "non-fast-forward" —
#      without this arm the previous one would license the wrong rule.
( cd "$W/other" && G commit -q --allow-empty -m other2 && git push -q origin linux-next )
b="$(refbytes "$W/wc" origin linux-next)"   # $W/wc has NOT fetched since
[ "${b:-0}" -gt 0 ] \
    && ok "non-ff with a STALE remote-tracking ref still carries a ref list ($b bytes)" \
    || bad "non-ff/stale — want a ref list, got '${b:-<none>}'; the rule would be mis-stated"

# ── 6. THE FIX: the real guard accepts an empty list instead of gating. ────
out="$(printf '' | bash "$GUARD" origin "$W/bare.git" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "the guard exits 0 on an empty ref list (rc=$rc)" \
    || bad "the guard must not gate a push that sends nothing (rc=$rc): $out"
printf '%s' "$out" | grep -q 'fetch and rebase' \
    && ok "the message names the real remedy (fetch and rebase)" \
    || bad "the message must not send the reader to ./build.sh --check: $out"
printf '%s' "$out" | grep -q 'build.sh --check' \
    && bad "the empty-list path must not mention the gate as the remedy" \
    || ok "no misleading gate remedy on the empty-list path"

hold_ambient_stamp   # arms 7-8 assert the guard REFUSES; a live stamp makes it accept

# ── 7. NEGATIVE CONTROL — a REAL outgoing ref is still gated. This fix must
#      not become a licence to accept an unscoped push (criterion 3).
out="$(printf 'refs/heads/x 1111111111111111111111111111111111111111 refs/heads/x 2222222222222222222222222222222222222222\n' \
       | bash "$GUARD" origin "$W/bare.git" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a non-empty ref list is still gated (rc=$rc) — no unscoped acceptance" \
    || bad "REGRESSION: a real outgoing ref was accepted without gating"

# ── 8. MUTATION CONTROL: strip the early accept and arm 6 must fail. ──────
PRE="$W/pre-877-guard.sh"
awk '/# ── ORDER 877-mynm: AN EMPTY REF LIST/{skip=1} skip && /^fi$/{skip=0; next} skip{next} {print}' \
    "$GUARD" > "$PRE"
out="$(printf '' | bash "$PRE" origin "$W/bare.git" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] \
    && ok "MUTATION: without the early accept the same empty list is refused — arm 6 has teeth" \
    || bad "mutation control did not reproduce the pre-fix behaviour (rc=$rc)"

restore_ambient_stamp

# ── 9. BISTABILITY CONTROL — arm 7 must give the SAME verdict whichever way the
#      ambient stamp happens to be, or this fixture is measuring the host's
#      parity instead of the guard. This is the arm that would have caught the
#      original defect; without it the contamination flips silently and the gate
#      alternates green/red on an unchanged tree.
REF='refs/heads/x 1111111111111111111111111111111111111111 refs/heads/x 2222222222222222222222222222222222222222'
hold_ambient_stamp
printf '%s\n' "$REF" | bash "$GUARD" origin "$W/bare.git" >/dev/null 2>&1; rc_absent=$?
restore_ambient_stamp
[ "$rc_absent" -ne 0 ] \
    && ok "BISTABILITY: arm 7's premise holds under controlled stamp absence (rc=$rc_absent)" \
    || bad "arm 7 cannot refuse even with the ambient stamp held aside (rc=$rc_absent) — its premise is gone"

echo "test-pre-push-empty-ref-list: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
