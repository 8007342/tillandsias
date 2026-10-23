#!/usr/bin/env bash
# @trace order:1833-ytbe, spec:local-coding-delegation
#
# Hermetic fixture for scripts/local-delegate.sh. Each arm builds a scratch git
# repo carrying a fixture ledger row (owned_files: greeting.txt; closure
# scripts/check-greeting.sh, which passes when greeting.txt says hello and
# counts its own runs) and drives the delegate against a STUB endpoint: a
# `curl` first on PATH that answers /v1/models and replays canned chat replies
# (reply-<n>.json, default: a finish call), saving each request it was sent.
# The no-endpoint arm uses the REAL curl against a port nothing listens on.
#
#   1 OK          write greeting.txt=hello, finish -> ok:...:ok:rounds=1:closure=passed;
#                 the closure ran exactly once; the edit is left uncommitted;
#                 `git log -1` unchanged
#   2 STRAY       write greeting.txt AND other.txt (not owned) -> out-of-scope;
#                 other.txt restored, tree clean, closure never ran, no commit
#   3 NO ENDPOINT http://127.0.0.1:1 -> no-endpoint, exit non-zero, tree untouched,
#                 and the stub log shows no chat request was ever attempted
#   4 RED         write greeting.txt=wrong, then finish every round with
#                 --max-rounds 2 -> closure-red:rounds=2; the closure ran twice;
#                 the second request carried the closure's failure output; tree clean
#   5 NO JQ/PY    the delegate's two files name neither tool
#
# PRE-FIX RESULT: FAILS — scripts/local-delegate.sh is absent, so every arm's
# verdict line is missing (arm 5 fails on the absent files).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DELEGATE="$ROOT/scripts/local-delegate.sh"
LUA="$ROOT/scripts/lua/local-delegate.lua"
pass=0; ran=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); ran=$((ran+1)); }
bad() { echo "FAIL: $1"; ran=$((ran+1)); }

_plan="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _plan=""
case "$_plan" in ./*) _plan="$ROOT/${_plan#./}" ;; esac
if [ -z "$_plan" ]; then
    echo "skip:test-local-delegate:no-plan-binary — build one: cargo build --release -p tillandsias-plan"
    exit 0
fi
export TILLANDSIAS_PLAN_BIN="$_plan"

_tmpbase="$ROOT/target/plan-scratch"; mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tmpbase/local-delegate.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# The stub transport. Real curl for anything that is not the stub host.
mkdir -p "$W/bin"
REAL_CURL="$(command -v curl)"
cat > "$W/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""; for a in "$@"; do case "$a" in http://*|https://*) url="$a" ;; esac; done
case "$url" in
    http://stub.invalid/*) ;;
    *) exec "$REAL_CURL" "$@" ;;
esac
d="$TILLANDSIAS_STUB_DIR"
case "$url" in
    */v1/models) printf '{"object":"list","data":[{"id":"stub"}]}\n'; exit 0 ;;
    */v1/chat/completions)
        n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$d/count"
        cat > "$d/req-$n.json"
        if [ -f "$d/reply-$n.json" ]; then cat "$d/reply-$n.json"
        else printf '%s\n' '{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"f","type":"function","function":{"name":"finish","arguments":"{\"summary\":\"done\"}"}}]}}]}'
        fi
        exit 0 ;;
esac
exit 22
EOF
sed -i.bak "s#\$REAL_CURL#$REAL_CURL#" "$W/bin/curl" && rm -f "$W/bin/curl.bak"
chmod +x "$W/bin/curl"

write_call() { # write_call <path> <content> -> one canned reply calling write_file
    printf '{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"w","type":"function","function":{"name":"write_file","arguments":"{\\"path\\":\\"%s\\",\\"content\\":\\"%s\\\\n\\"}"}}]}}]}\n' "$1" "$2"
}

mkrepo() { # mkrepo <dir>
    local d="$1"
    mkdir -p "$d/repo/plan/index.d" "$d/repo/scripts" "$d/stub"
    printf 'packets: []\n' > "$d/repo/plan/index.yaml"
    cat > "$d/repo/plan/index.d/20261023t000000z-00000000-fixture.yaml" <<'EOF'
packets:
  - packet_id: fixture-greeting-says-hello
    order: 9-ldfx
    status: ready
    kind: feature
    priority: p2
    pickup_role: any
    owned_files:
      - greeting.txt
    title: greeting.txt says hello
    exit_criteria:
      - 'greeting.txt contains hello'
    verifiable_closure: 'bash scripts/check-greeting.sh exits 0 (pre-fix result: FAILS — greeting.txt says hi)'
EOF
    cat > "$d/repo/scripts/check-greeting.sh" <<'EOF'
#!/usr/bin/env bash
echo run >> "$TILLANDSIAS_STUB_DIR/closure-runs"
grep -qx hello greeting.txt && { echo "ok:greeting"; exit 0; }
echo "FAIL: greeting.txt is '$(cat greeting.txt)', want hello"; exit 1
EOF
    printf 'hi\n' > "$d/repo/greeting.txt"
    printf 'keep me\n' > "$d/repo/other.txt"
    git -C "$d/repo" init -q
    git -C "$d/repo" add -A
    git -C "$d/repo" -c user.name=fixture -c user.email=fixture@example.invalid \
        -c commit.gpgsign=false commit -qm fixture
}

drive() { # drive <dir> <endpoint> [args...] -> sets OUT RC
    local d="$1" ep="$2"; shift 2
    OUT="$(cd "$d/repo" && PATH="$W/bin:$PATH" TILLANDSIAS_STUB_DIR="$d/stub" \
        TILLANDSIAS_INFERENCE_ENDPOINT="$ep" bash "$DELEGATE" implement 9-ldfx --model stub "$@" 2>"$d/stderr")"
    RC=$?
}
head_of() { git -C "$1/repo" rev-parse HEAD; }
clean() { [ -z "$(git -C "$1/repo" status --porcelain --untracked-files=all)" ]; }
runs() { [ -f "$1/stub/closure-runs" ] && wc -l < "$1/stub/closure-runs" | tr -d ' ' || echo 0; }

# 1 — in-bounds edit, passing closure.
A="$W/a1"; mkrepo "$A"; h0="$(head_of "$A")"
write_call greeting.txt hello > "$A/stub/reply-1.json"
drive "$A" http://stub.invalid
if [ "$OUT" = "ok:local-delegate:9-ldfx:ok:rounds=1:closure=passed" ] && [ "$RC" -eq 0 ] \
   && [ "$(runs "$A")" = 1 ] && [ "$(head_of "$A")" = "$h0" ] \
   && [ "$(cat "$A/repo/greeting.txt")" = hello ] \
   && [ "$(git -C "$A/repo" status --porcelain)" = " M greeting.txt" ]; then
    ok "1 in-bounds edit + passing closure -> ok, closure ran once, edit uncommitted"
else
    bad "1 got '$OUT' rc=$RC runs=$(runs "$A") status='$(git -C "$A/repo" status --porcelain | tr '\n' ' ')'"; sed 's/^/    /' "$A/stderr"
fi

# 2 — a stray edit outside owned_files.
A="$W/a2"; mkrepo "$A"; h0="$(head_of "$A")"
write_call greeting.txt hello > "$A/stub/reply-1.json"
write_call other.txt hacked > "$A/stub/reply-2.json"
drive "$A" http://stub.invalid
if [ "$OUT" = "refused:local-delegate:9-ldfx:out-of-scope:other.txt" ] && [ "$RC" -ne 0 ] \
   && clean "$A" && [ "$(cat "$A/repo/other.txt")" = "keep me" ] \
   && [ "$(runs "$A")" = 0 ] && [ "$(head_of "$A")" = "$h0" ]; then
    ok "2 stray edit -> out-of-scope, other.txt restored, tree clean, closure not run, no commit"
else
    bad "2 got '$OUT' rc=$RC runs=$(runs "$A") other='$(cat "$A/repo/other.txt")'"; sed 's/^/    /' "$A/stderr"
fi

# 3 — endpoint down: fail-closed before anything is read or written.
A="$W/a3"; mkrepo "$A"; h0="$(head_of "$A")"
drive "$A" http://127.0.0.1:1
if [ "$OUT" = "refused:local-delegate:9-ldfx:no-endpoint" ] && [ "$RC" -ne 0 ] \
   && clean "$A" && [ ! -f "$A/stub/count" ] && [ "$(head_of "$A")" = "$h0" ]; then
    ok "3 endpoint down -> no-endpoint, non-zero, tree untouched"
else
    bad "3 got '$OUT' rc=$RC"; sed 's/^/    /' "$A/stderr"
fi

# 4 — the closure stays red through --max-rounds.
A="$W/a4"; mkrepo "$A"; h0="$(head_of "$A")"
write_call greeting.txt wrong > "$A/stub/reply-1.json"
drive "$A" http://stub.invalid --max-rounds 2
if [ "$OUT" = "refused:local-delegate:9-ldfx:closure-red:rounds=2" ] && [ "$RC" -ne 0 ] \
   && [ "$(runs "$A")" = 2 ] && clean "$A" && [ "$(head_of "$A")" = "$h0" ] \
   && grep -q "want hello" "$A/stub/req-3.json"; then
    ok "4 red closure -> closure-red:rounds=2, ran twice, failure fed back, tree clean"
else
    bad "4 got '$OUT' rc=$RC runs=$(runs "$A")"; sed 's/^/    /' "$A/stderr"
fi

# 5 — the delegate names neither forbidden tool.
if [ -f "$DELEGATE" ] && [ -f "$LUA" ] && ! grep -nwiE 'jq|python[0-9.]*' "$DELEGATE" "$LUA"; then
    ok "5 no jq or python in the delegate"
else
    bad "5 delegate absent or names jq/python"
fi

if [ "$pass" -eq "$ran" ] && [ "$ran" -eq 5 ]; then
    echo "PASS: local-delegate fixture"
    echo "ok:test-local-delegate:$pass"
    exit 0
fi
echo "refused:test-local-delegate:$pass/$ran"
exit 1
