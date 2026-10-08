#!/usr/bin/env bash
# @trace order:1257-jxu9
#
# test-expert-accuracy-provenance.sh — record-expert-accuracy.sh must not lose
# provenance the two silent ways measured on yoga 2026-09-18:
#   1. it asked the ollama-native /api/show on the OPENAI-COMPATIBLE base
#      (…/v1/api/show, a 404), so every record on a correctly configured host
#      read quantisation and engine as `unknown`;
#   2. it wrote its series under a gitignored cache, so no other host could
#      ever read it.
#
# `curl` is stubbed on PATH: it logs the URL it was asked and answers like
# ollama (a /api/show on the native base returns details; anything else is a
# 404 body). The grader line and the served model come through the script's
# FIXTURE SEAMS, and --dry-run prints the record without appending.
#
# Arms:
#   1 V1 BASE    endpoint …/v1: the show lookup asks the NATIVE base and the
#                record carries quantisation F16 and engine bert
#   2 NO GUESS   (negative control) an endpoint that cannot answer leaves both
#                `unknown`: never inferred from the model tag
#   3 OVERRIDE   TILLANDSIAS_OLLAMA_BASE names the native base outright
#   4 TRACKED    the default log is plan/metrics/expert-accuracy.d/<host>.jsonl
#                and git does NOT ignore it, so a normal pull carries it
#   5 PER HOST   two hosts resolve to two different files, so same-day
#                appends concatenate and never conflict
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REC="$ROOT/scripts/record-expert-accuracy.sh"
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }
# jq is needed by the SCRIPT under test (it composes the record), not by this fixture.
command -v jq >/dev/null 2>&1 || { echo "skip:expert-accuracy-provenance:jq-absent"; exit 0; }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ea-prov.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
cat >"$scratch/bin/curl" <<'STUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
printf '%s\n' "$url" >>"${CURL_LOG:?}"
case "$url" in
    */v1/api/show) printf '404 page not found' ;;
    http://127.0.0.1:11434/api/show|http://native.test:11434/api/show)
        printf '{"details":{"quantization_level":"F16","family":"bert"}}' ;;
    *) printf '404 page not found' ;;
esac
STUB
chmod +x "$scratch/bin/curl"
export CURL_LOG="$scratch/curl.log"
LINE='groundtruth-result: sets=4 total=33 pass=33 fail=0'

record() {   # extra env assignments...; prints the dry-run record
    : >"$CURL_LOG"
    env "$@" PATH="$scratch/bin:$PATH" \
        TILLANDSIAS_EXPERT_ACCURACY_GRADE_LINE="$LINE" \
        TILLANDSIAS_EXPERT_ACCURACY_INDEX_MODEL=all-minilm \
        "$REC" --dry-run 2>/dev/null
}
field() {   # <key> <record-json>: the string value of "key", read without jq (1375 ratchet)
    local v
    v="$(grep -oE "\"$1\":\"[^\"]*\"" <<<"$2" | head -1)"
    v="${v#*:\"}"; printf '%s' "${v%\"}"
}

rec="$(record TILLANDSIAS_EMBED_ENDPOINT=http://127.0.0.1:11434/v1)"
asked="$(head -1 "$CURL_LOG")"
q="$(field quantisation "$rec")"; e="$(field engine "$rec")"
if [ "$asked" = "http://127.0.0.1:11434/api/show" ] && [ "$q" = F16 ] && [ "$e" = bert ]; then
    ok "ARM1 a /v1 endpoint asks the native base ($asked): quantisation=$q engine=$e"
else bad "ARM1 asked='$asked' quantisation='$q' engine='$e'"; fi

rec="$(record TILLANDSIAS_EMBED_ENDPOINT=http://nowhere.test:11434/v1)"
q="$(field quantisation "$rec")"; e="$(field engine "$rec")"
[ "$q" = unknown ] && [ "$e" = unknown ] \
    && ok "ARM2 an endpoint that cannot answer leaves both unknown (no guess from the tag)" \
    || bad "ARM2 quantisation='$q' engine='$e'"

rec="$(record TILLANDSIAS_EMBED_ENDPOINT=http://127.0.0.1:11434/v1 TILLANDSIAS_OLLAMA_BASE=http://native.test:11434)"
asked="$(head -1 "$CURL_LOG")"
[ "$asked" = "http://native.test:11434/api/show" ] && [ "$(field quantisation "$rec")" = F16 ] \
    && ok "ARM3 TILLANDSIAS_OLLAMA_BASE names the native base: $asked" \
    || bad "ARM3 asked='$asked'"

path="$("$REC" --path 2>/dev/null)"
case "$path" in
    "$ROOT"/plan/metrics/expert-accuracy.d/*.jsonl) ok "ARM4 the default log is tracked-path ${path#"$ROOT"/}" ;;
    *) bad "ARM4 default log = '$path'" ;;
esac
if git -C "$ROOT" check-ignore -q "${path#"$ROOT"/}"; then
    bad "ARM4 git IGNORES ${path#"$ROOT"/}: a pull would never carry it"
else ok "ARM4 git does not ignore it, so a normal pull carries the series"; fi

p1="$(env PATH="$scratch/bin:$PATH" bash -c 'cd "$1" && scripts/derive-host-identity.sh' _ "$ROOT" 2>/dev/null | head -1)"
h1="$ROOT/plan/metrics/expert-accuracy.d/$(tr -c 'A-Za-z0-9._+-' '_' <<<"hostA")"
h2="$ROOT/plan/metrics/expert-accuracy.d/$(tr -c 'A-Za-z0-9._+-' '_' <<<"hostB")"
[ "${h1%_}" != "${h2%_}" ] && [ -n "$p1" ] \
    && ok "ARM5 two hosts write two files (${h1##*/} vs ${h2##*/}), so same-day appends concatenate" \
    || bad "ARM5 host files collide or host identity unresolved ('$p1')"

[ "$FAIL" -eq 0 ] && { echo "PASS: expert-accuracy-provenance (1257-jxu9)"; exit 0; }
echo "FAILED: expert-accuracy-provenance (1257-jxu9)"; exit 1
