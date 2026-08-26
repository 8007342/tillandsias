#!/usr/bin/env bash
# @trace order:858-ihcb, spec:inference-container
#
# Fixture for order 858-ihcb: no prompt may reach a MEASURED call twice.
#
# WHY THIS EXISTS, and why it intercepts curl rather than testing a helper in
# isolation. bench-inference-floor.sh warmed up with the identical prompt and
# then measured it, so `prompt_eval_duration` covered a cache hit and
# `prefill_tok_s` was inflated ~13x (1528 reported against a true 113 on
# esmeraldinha, 2026-08-23).
#
# The FIRST fix was itself wrong in a way a unit test of the helper would have
# passed: `unique_prompt` incremented a global counter, but every call site
# invokes it inside `$( ... )`, which runs in a subshell — so the counter never
# advanced in the parent and every prompt was byte identical anyway. The
# harness reported 1528 tok/s again while looking fixed. A test that called
# `unique_prompt` directly in one shell would have seen three different strings
# and passed.
#
# So this fixture runs the REAL script and inspects the payloads its REAL call
# sites actually put on the wire, by putting a stub `curl` first on PATH. That
# is the only level at which the subshell defect is visible.
#
# HERMETIC: stub curl, stub jq passthrough not needed (real jq is used to build
# payloads), no network, no ollama, no repo writes. Everything under mktemp.
set -uo pipefail


# ORDER 799-tb7q — resolve `jq` through the shared host-preferred /
# toolbox-fallback dispatch instead of assuming the host has it.
# shellcheck source=scripts/lib/tool-dispatch.sh
# Resolve the lib by WALKING UP, not by a fixed depth (order 914-ahsy). The
# fixed form `dirname "${BASH_SOURCE[0]}"/lib/...` is correct only for a caller
# sitting directly in scripts/. From scripts/refusal-calibration/ it points at a
# lib that does not exist, the `|| true` swallows the miss, and the tool variable
# silently falls back to the bare name — a conversion that passes review, passes
# the suite, and changes nothing.
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
if command -v resolve_tool >/dev/null 2>&1; then
    JQ="$(resolve_tool jq || printf 'jq')"
else
    JQ="jq"   # lib unavailable: preserve the previous behaviour exactly
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$ROOT/scripts/bench-inference-floor.sh"

pass=0; fail=0
ck() { # ck <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else
        printf '  FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}

command -v jq >/dev/null 2>&1 || { echo "skip:jq-absent"; exit 0; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/bench-prompt-uniqueness.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin"

PROMPT_LOG="$TMPD/prompts.log"
: > "$PROMPT_LOG"

# Stub curl: dispatches on the URL, logs every /api/generate prompt, and
# answers with fixed timings. Deliberately reports a CONSTANT prefill rate, so
# any variation in the harness's output would come from its own arithmetic
# rather than from the endpoint.
cat > "$TMPD/bin/curl" <<STUB
#!/usr/bin/env bash
url=""; data=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -d) shift; data="\$1" ;;
        http*) url="\$1" ;;
    esac
    shift
done
[ "\$data" = "@-" ] && data="\$(cat)"
case "\$url" in
    */api/version) printf '{"version":"stub"}'; exit 0 ;;
    */api/ps)      printf '{"models":[{"name":"stub","size":100,"size_vram":0}]}'; exit 0 ;;
    */api/embed)   printf '{"embeddings":[[0.0]]}'; exit 0 ;;
    */api/generate)
        printf '%s\n' "\$data" | jq -r '.prompt' >> "$PROMPT_LOG"
        # 100 prompt tokens in 1s => 100 tok/s; 200 eval tokens in 10s => 20 tok/s
        printf '{"prompt_eval_count":100,"prompt_eval_duration":1000000000,"eval_count":200,"eval_duration":10000000000,"load_duration":1000000,"total_duration":11000000000}'
        exit 0 ;;
esac
exit 1
STUB
chmod +x "$TMPD/bin/curl"

echo "bench-prompt-uniqueness: 858-ihcb"

out="$(cd "$TMPD" && env PATH="$TMPD/bin:$PATH" \
        BENCH_ENDPOINT="http://stub" \
        BENCH_MODELS="stubmodel=T0" \
        BENCH_EMBED_N=1 \
        BENCH_PREFILL_REPS=3 \
        bash "$SUT" 2>/dev/null)"

total="$(wc -l < "$PROMPT_LOG" | tr -d ' ')"
uniq_n="$(sort -u "$PROMPT_LOG" | wc -l | tr -d ' ')"

# THE test. Warm-up + (REPS+1) prefill probes + 1 decode = 6 generate calls,
# and every one of them must carry a prompt no earlier call used. A reused
# prompt anywhere means a warm cache reached a measured call.
ck "every /api/generate prompt is distinct" "$total" "$uniq_n"
ck "expected number of generate calls" "6" "$total"

# The unique part must be near the FRONT. ollama reuses a matching PREFIX, so a
# shared prefix with a unique tail still measures only the novel tail while
# prompt_eval_count reports the whole prompt — measured at 366-474 tok/s
# against a true ~113 when the nonce was appended instead of prepended.
shared="$(awk 'NR==1{a=$0} NR==2{b=$0;
    n=0; while (n < length(a) && n < length(b) && substr(a,n+1,1)==substr(b,n+1,1)) n++;
    print n}' "$PROMPT_LOG")"
if [ "${shared:-999}" -le 24 ]; then
    printf '  ok   distinguishing text is within the first 24 chars (shared prefix=%s)\n' "$shared"
    pass=$((pass+1))
else
    printf '  FAIL distinguishing text is too deep (shared prefix=%s chars)\n' "$shared"
    fail=$((fail+1))
fi

# The reported prefill rate must come from the isolated probes, not from the
# decode call. With the stub answering a constant 100 tok/s, anything else
# means the harness is deriving prefill from the wrong response again.
ck "prefill_tok_s comes from the isolated probes" "100.00" \
   "$(printf '%s\n' "$out" | sed -n 's/.*prefill_tok_s=\([0-9.]*\).*/\1/p')"
ck "prefill_n reports the kept sample size" "3" \
   "$(printf '%s\n' "$out" | sed -n 's/.*prefill_n=\([0-9]*\).*/\1/p')"

# With no measured corpus count the projection must decline rather than
# multiply a stale constant (the second half of 858-ihcb).
ck "projection declines without a measured chunk count" "skipped:no-measured-corpus-chunk-count" \
   "$(printf '%s\n' "$out" | sed -n 's/.*full_rebuild=\([a-z:-]*\).*/\1/p')"

printf 'bench-prompt-uniqueness: %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
    echo "ok:bench-prompt-uniqueness:$pass"
    exit 0
fi
echo "fail:bench-prompt-uniqueness:$fail"
exit 1
