#!/usr/bin/env bash
# @trace spec:meta-orchestration
# @trace order:1004-8vkv
#
# Fixture for loop-status-append's INPUT handling.
#
# WHY THIS IS WRITTEN FIRST: the two bad outcomes are not reproducible by
# reading the code, and one of them is invisible. Measured by
# lenovinha-silverblue 2026-09-04 on its own finalize step —
# `loop-status-append <file>` dropped the path, read stdin, and with an
# inherited SOCKET on fd 0 blocked for 26 MINUTES at 0.0% CPU in
# unix_stream_data_wait before /proc was consulted. A forge agent's stdin is a
# socket by construction, nothing in the cycle times out on it, and a host
# stuck there looks exactly like a host mid-analysis.
#
# The second outcome is worse because it is confident: re-run with a closed
# stdin, the same invocation reported "fragment carries no `## Cycle` section"
# against a fragment whose first bytes were byte-identical to one that worked.
# That sends the reader to edit a file the tool never opened. pirria's
# 2026-08-31 smoke hit the same message behind `--help`; this fixture also
# covers the empty-read arm that all three surfaces share.
#
# EVERY ARM RUNS THE REAL BINARY. A test that asserts on argument parsing in
# isolation would not have caught either outcome, because both are about what
# the process does with fd 0 when the arguments look fine.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 721-nyev: resolve through the SHARED probe, never a hardcoded target/ path.
# An executable bit is a claim; running the binary is evidence.
. "$ROOT/scripts/plan-binary-probe.sh"
BIN="$(resolve_plan_binary)" || { echo "blocked:no-plan-binary"; exit 2; }
case "$BIN" in /*) ;; *) BIN="$ROOT/${BIN#./}" ;; esac
[ -x "$BIN" ] || { echo "blocked:no-plan-binary:$BIN"; exit 2; }

# A bounded runner. `timeout` is not in /usr/bin on macOS (homebrew coreutils
# lands it in /opt/homebrew/bin) and a sealed PATH strands it, so resolve it
# rather than assuming, and skip the hang arms loudly if none is available —
# silently passing an unbounded arm is the failure this fixture exists to stop.
TIMEOUT_BIN=""
for cand in timeout gtimeout; do
    if command -v "$cand" >/dev/null 2>&1; then TIMEOUT_BIN="$cand"; break; fi
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ls-append-input.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; skipped=0
check() {
    if [ "$1" = ok ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$2"
    else fail=$((fail + 1)); printf 'FAIL %s\n' "$2"; [ -n "${3:-}" ] && printf '     %s\n' "$3"; fi
}

# A real repo, so the writer has somewhere to land and the arms are not
# rejected for an unrelated reason.
git init -q -b main "$tmp/repo"
cd "$tmp/repo" || exit 2
git config user.email f@f; git config user.name f
mkdir -p plan/loop_status.d
printf '# loop status\n' > plan/loop_status.md
git add -A && git commit -qm base

frag="$tmp/fragment.md"
cat > "$frag" <<'FRAGEOF'
## Cycle 2026-09-04T10:45:00Z (tlatoanis-macbook-air — fixture)

Written by scripts/test-loop-status-append-input.sh.
FRAGEOF

# ── 1. A BARE POSITIONAL IS NEVER SILENTLY DROPPED ─────────────────────────
# Honoured or refused with a usage error naming both sanctioned forms.
# Dropping it is what sent lenovinha into the socket wait.
before="$(ls plan/loop_status.d | wc -l | tr -d ' ')"
out="$("$BIN" loop-status-append "$frag" </dev/null 2>&1)"; rc=$?
after="$(ls plan/loop_status.d | wc -l | tr -d ' ')"
if [ "$after" -gt "$before" ]; then
    check ok "a bare positional path is honoured as the fragment"
elif [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -e '--file' && printf '%s' "$out" | grep -q '<'; then
    check ok "a bare positional path is refused with a usage error naming both forms"
else
    check FAIL "a bare positional path is honoured or refused, never dropped" \
        "rc=$rc out=[$(printf '%s' "$out" | tail -2)]"
fi

# ── 2. A SOCKET ON fd 0 IS REFUSED, NOT WAITED ON ──────────────────────────
# THE ARM THIS PACKET EXISTS FOR. Exit 124 is timeout(1) killing it, i.e. the
# 26-minute wait reproduced in miniature.
if [ -z "$TIMEOUT_BIN" ]; then
    echo "skip  a socket on fd 0 is refused within a bounded time (no timeout/gtimeout on PATH)"
    skipped=$((skipped + 1))
else
    # A socketpair on fd 0 with nothing written and the peer held open: the
    # exact shape an inherited agent stdin has. `nc -lU` would need a listener
    # dance; bash's /dev/tcp cannot make a unix socket, so use a FIFO-backed
    # socket via python-free means — a unix socket from `nc -U` if present,
    # else a FIFO, which reproduces the same blocking read on fd 0.
    fifo="$tmp/stdin.fifo"
    mkfifo "$fifo" 2>/dev/null
    # Hold the write end open forever so the read never sees EOF.
    sleep 300 > "$fifo" &
    holder=$!
    # NO positional and no --file: stdin is the only input, which is the
    # invocation that hung. An earlier draft of this arm passed the fragment
    # path as well, so once the positional was honoured the command succeeded
    # without ever reading fd 0 — the arm would have gone green while testing
    # nothing.
    out="$("$TIMEOUT_BIN" 10 "$BIN" loop-status-append --host fixture < "$fifo" 2>&1)"; rc=$?
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    if [ "$rc" -eq 124 ]; then
        check FAIL "a blocking stdin is refused within a bounded time" \
            "the process waited until timeout(1) killed it (exit 124) — this is the 26-minute hang"
    elif [ "$rc" -ne 0 ]; then
        check ok "a blocking stdin is refused within a bounded time, not waited on"
    else
        check FAIL "a blocking stdin is refused within a bounded time" "rc=0 out=[$out]"
    fi
fi

# ── 3. AN EMPTY READ SAYS SO ───────────────────────────────────────────────
# "fragment carries no ## Cycle section" against zero bytes is a false report
# about a file that was never opened. The message must name what it read.
out="$("$BIN" loop-status-append </dev/null 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi '0 bytes'; then
    check ok "an empty stdin names the byte count rather than blaming the fragment's shape"
else
    check FAIL "an empty stdin names the byte count" "rc=$rc out=[$(printf '%s' "$out" | tail -2)]"
fi

# ── 4/5. POSITIVE CONTROLS — without these the arms above are satisfied by a
#         binary that refuses everything.
out="$("$BIN" loop-status-append --host fixture < "$frag" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'plan/loop_status.d/'; then
    check ok "the stdin form still writes a fragment"
else
    check FAIL "the stdin form still writes a fragment" "rc=$rc out=[$(printf '%s' "$out" | tail -2)]"
fi

out="$("$BIN" loop-status-append --host fixture --file "$frag" </dev/null 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'plan/loop_status.d/'; then
    check ok "the --file form still writes a fragment"
else
    check FAIL "the --file form still writes a fragment" "rc=$rc out=[$(printf '%s' "$out" | tail -2)]"
fi

# ── 6. A MALFORMED FRAGMENT IS A DIFFERENT SENTENCE FROM AN EMPTY READ ─────
bad="$tmp/bad.md"
printf '# Cycle 2026-09-04T10:45:00Z (single hash, wrong level)\n\nbody\n' > "$bad"
out="$("$BIN" loop-status-append --host fixture --file "$bad" </dev/null 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -qi '0 bytes'; then
    check ok "a malformed fragment reports its shape, not an empty read"
else
    check FAIL "a malformed fragment reports its shape" "rc=$rc out=[$(printf '%s' "$out" | tail -2)]"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: loop-status-append input handling ${pass}/${total} (1004-8vkv)$( [ "$skipped" -gt 0 ] && printf ', %%s skipped' "$skipped" )"
    exit 0
fi
echo "FAIL: loop-status-append input handling ${fail}/${total} red (1004-8vkv)"
exit 1
