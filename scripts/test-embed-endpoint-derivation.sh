#!/usr/bin/env bash
# test-embed-endpoint-derivation.sh — pin images/default/lib-embed-endpoint.sh.
# @trace order:967-xq5e
#
# The defect this guards: scripts/spec-index-ensure.sh INHERITED
# TILLANDSIAS_EMBED_ENDPOINT and refused when absent, while every derivation
# lived in the forge lane. The host lane therefore never refreshed an index
# anywhere — 32 consecutive skips on macuahuitl, and the one host that worked
# did so because of a git-ignored settings file.
#
# No network: the probe is a stub `curl` on PATH, so every arm is hermetic.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
LIB="images/default/lib-embed-endpoint.sh"
pass=0; fail=0
STUB="$(mktemp -d "${TMPDIR:-/tmp}/embed-ep-stub.XXXXXX")"
trap 'rm -rf "$STUB"' EXIT

# Stub curl: succeeds only for the URL named in $STUB_OK.
cat > "$STUB/curl" <<'CURL'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in http*) url="$a";; esac; done
[ -n "${STUB_OK:-}" ] && [ "$url" = "$STUB_OK" ] && exit 0
exit 7
CURL
chmod +x "$STUB/curl"

check() { # name expected_verdict expected_ep  <env assignments...>
    local name="$1" want_v="$2" want_ep="$3"; shift 3
    local out
    out="$(env "$@" PATH="$STUB:$PATH" bash -c ". $LIB; resolve_embed_endpoint >/dev/null 2>&1; printf '%s|%s' \"\${TILLANDSIAS_EMBED_ENDPOINT_VERDICT:-none}\" \"\${TILLANDSIAS_EMBED_ENDPOINT:-unset}\"")"
    local got_v="${out%%|*}" got_ep="${out##*|}"
    if [ "$got_v" = "$want_v" ] && [ "$got_ep" = "$want_ep" ]; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "FAIL: $name"
        echo "  verdict want=[$want_v] got=[$got_v]"
        echo "  endpoint want=[$want_ep] got=[$got_ep]"
    fi
}

# 1. An explicit endpoint is never probed and never overridden — the caller has
#    spoken, and probing it would let a transient outage silently unwire it.
check "explicit wins unprobed" \
    "ok:embed-endpoint:explicit:http://explicit:1/v1" "http://explicit:1/v1" \
    TILLANDSIAS_EMBED_ENDPOINT=http://explicit:1/v1

# 2. Host lane derives loopback (the dev inference container's published port).
check "host derives loopback" \
    "ok:embed-endpoint:derived:http://127.0.0.1:11434/v1" "http://127.0.0.1:11434/v1" \
    -u TILLANDSIAS_EMBED_ENDPOINT -u TILLANDSIAS_INFERENCE_ENDPOINT -u OLLAMA_HOST \
    STUB_OK=http://127.0.0.1:11434/v1/models

# 3. Forge lane derives the enclave service name, NOT loopback. `inference`
#    resolves only inside the enclave; a host using it would probe a name that
#    cannot resolve, and a forge using loopback would find its own empty port.
check "forge derives enclave service" \
    "ok:embed-endpoint:derived:http://inference:11434/v1" "http://inference:11434/v1" \
    -u TILLANDSIAS_EMBED_ENDPOINT -u TILLANDSIAS_INFERENCE_ENDPOINT -u OLLAMA_HOST \
    TILLANDSIAS_HOST_KIND=forge STUB_OK=http://inference:11434/v1/models

# 4. PROBE, DO NOT ASSUME (712-r5x8). Nothing answers -> nothing is exported,
#    so spec_answer keeps its honest `no embedding endpoint` refusal instead of
#    the misleading `the endpoint did not answer`.
check "unreachable exports nothing" \
    "unreachable:embed-endpoint:http://127.0.0.1:11434/v1" "unset" \
    -u TILLANDSIAS_EMBED_ENDPOINT -u TILLANDSIAS_INFERENCE_ENDPOINT -u OLLAMA_HOST

# 5. A root url gains /v1; one already spelled /v1 does NOT gain a second, which
#    would 404 on /v1/v1/embeddings.
check "root url gains /v1" \
    "ok:embed-endpoint:derived:http://host:9/v1" "http://host:9/v1" \
    -u TILLANDSIAS_EMBED_ENDPOINT -u OLLAMA_HOST \
    TILLANDSIAS_INFERENCE_ENDPOINT=http://host:9 STUB_OK=http://host:9/v1/models
check "existing /v1 not doubled" \
    "ok:embed-endpoint:derived:http://host:9/v1" "http://host:9/v1" \
    -u TILLANDSIAS_EMBED_ENDPOINT -u OLLAMA_HOST \
    TILLANDSIAS_INFERENCE_ENDPOINT=http://host:9/v1 STUB_OK=http://host:9/v1/models

# 6. OLLAMA_HOST is one operator's spelling and takes precedence over the
#    convention default when set.
check "OLLAMA_HOST honoured" \
    "ok:embed-endpoint:derived:http://olla:2/v1" "http://olla:2/v1" \
    -u TILLANDSIAS_EMBED_ENDPOINT -u TILLANDSIAS_INFERENCE_ENDPOINT \
    OLLAMA_HOST=http://olla:2 STUB_OK=http://olla:2/v1/models

# 7. THE SUBSHELL TRAP, pinned because it was made and shipped-then-caught while
#    writing this fix. `v="$(resolve_embed_endpoint)"` runs in a SUBSHELL, so the
#    export dies there: the verdict says `derived` while the caller's variable is
#    still unset — a verdict contradicting the state it describes. Any caller
#    that regresses to the substitution form reproduces exactly that, so the
#    property is asserted rather than only documented.
sub_out="$(env -u TILLANDSIAS_EMBED_ENDPOINT -u TILLANDSIAS_INFERENCE_ENDPOINT -u OLLAMA_HOST \
    STUB_OK=http://127.0.0.1:11434/v1/models PATH="$STUB:$PATH" \
    bash -c ". $LIB; v=\"\$(resolve_embed_endpoint)\"; printf '%s|%s' \"\$v\" \"\${TILLANDSIAS_EMBED_ENDPOINT:-unset}\"")"
if [ "${sub_out##*|}" = "unset" ]; then
    pass=$((pass+1))   # the trap still exists; the contract comment is earning its place
else
    fail=$((fail+1)); echo "FAIL: subshell trap no longer reproduces — update the contract comment in $LIB"
fi

# 8. The real caller must NOT use the substitution form.
if grep -q '_sie_verdict="\$(resolve_embed_endpoint)"' scripts/spec-index-ensure.sh; then
    fail=$((fail+1)); echo "FAIL: spec-index-ensure.sh calls resolve_embed_endpoint in a command substitution (see arm 7)"
else
    pass=$((pass+1))
fi

# 9. Single source: nothing outside the helper may re-derive the endpoint.
#    A second derivation is the drift (967-6ax6, one container name in two
#    places). lib-common.sh and lib-dev-env.sh are the historic sites.
# Match EXECUTABLE assignments only: a line whose first non-space token is the
# export. Prose that quotes the assignment (this file, lib-common.sh's own
# rationale, the endpoint-contract cheatsheet) is documentation, not a copy —
# grepping the string rather than the statement made all three read as
# violations on the first run.
copies="$(grep -rlnE '^[[:space:]]*export[[:space:]]+TILLANDSIAS_EMBED_ENDPOINT=' \
    --include='*.sh' images/ scripts/ 2>/dev/null \
    | grep -v 'lib-embed-endpoint\.sh' || true)"
if [ -z "$copies" ]; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: a second derivation of TILLANDSIAS_EMBED_ENDPOINT exists:"
    printf '  %s\n' $copies
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: embed-endpoint derivation $pass/$total (967-xq5e)"
    exit 0
fi
echo "FAIL: embed-endpoint derivation $pass/$total (967-xq5e)"
exit 1
