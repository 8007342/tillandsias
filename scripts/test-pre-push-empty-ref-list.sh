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
trap 'rm -rf "$W"' EXIT INT TERM
export GIT_TERMINAL_PROMPT=0
G() { git -c user.email=t@t -c user.name=t "$@"; }

git init -q --bare "$W/bare.git"
git init -q -b linux-next "$W/wc"; ( cd "$W/wc" && git remote add origin "$W/bare.git" )
git init -q -b linux-next "$W/other"; ( cd "$W/other" && git remote add origin "$W/bare.git" )

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

echo "test-pre-push-empty-ref-list: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
