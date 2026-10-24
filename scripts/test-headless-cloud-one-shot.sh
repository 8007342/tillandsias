#!/usr/bin/env bash
# test-headless-cloud-one-shot.sh — 1847-5xv3: `tillandsias --cloud <o/r>
# --opencode` (or --codex) with no terminal on stdin is a one-shot.
#
#   1 PROMPT    no --prompt runs the queue default (read your queue messages,
#               else print idle:no-queued-work and exit); a given prompt wins;
#               an interactive start (a tty, a host checkout, a Claude lane) is
#               unchanged
#   2 BACKSTOP  past TILLANDSIAS_ONE_SHOT_MAX_MINUTES (default 90) the forge is
#               removed, failed:timeout is printed and reported, and the
#               launcher exits 124 through its own return path, so the Vault
#               credential cleanup still runs
#   3 QUEUE     the report goes through the QueueClient seam; NoQueue posts
#               nothing until 1826's coordinator client lands
#   4 WIRING    both agent dispatch sites check timed_out() after the cleanup
#               wrapper returns, and the prompt is resolved before either
#
# REUSED, not tested here: exit-on-agent-exit. Measured on lenovinha
# 2026-10-24 (v56.10.20.1): a --cloud --opencode --prompt run exited 0 in 67 s
# and `podman ps -a` afterwards held no forge (progress event on 1847-5xv3).
#
# 1-3 are the unit tests in crates/tillandsias-headless/src/one_shot.rs (a real
# thread, a recording teardown and queue); 4 reads main.rs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
MAIN="$ROOT/crates/tillandsias-headless/src/main.rs"

out="$(cd "$ROOT" && cargo test -q -p tillandsias-headless --bin tillandsias --features tray,listen-vsock one_shot:: 2>&1)"
if grep -qE '^test result: ok\. [1-9][0-9]* passed' <<<"$out"; then
    ok "1-3 one_shot unit tests pass ($(printf '%s\n' "$out" | grep -oE '[0-9]+ passed' | tail -1))"
else
    printf '%s\n' "$out" | tail -20
    bad "1-3 one_shot unit tests"
fi

n="$(grep -c 'if one_shot::timed_out() {' "$MAIN")"
[ "$n" = 2 ] && ok "4 both agent dispatch sites honour the timeout" || bad "4 timed_out() checks: $n, want 2"
grep -q 'let prompt = one_shot::effective_prompt(prompt, one_shot);' "$MAIN" \
    && ok "4 the prompt is resolved before dispatch" || bad "4 effective_prompt not wired"
grep -q 'one_shot::is_one_shot(is_cloud, opencode || codex, io::stdin().is_terminal())' "$MAIN" \
    && ok "4 only --opencode/--codex on --cloud without a tty" || bad "4 is_one_shot call changed"
grep -q 'Box::new(one_shot::NoQueue)' "$MAIN" \
    && ok "4 the queue post is the no-op client" || bad "4 NoQueue not wired"

if [ "$fail" -gt 0 ]; then echo "violation:headless-cloud-one-shot:$fail"; exit 1; fi
echo "ok:headless-cloud-one-shot:$pass"
