#!/usr/bin/env bash
# @trace order:1505-svve
# @trace openspec:changes/cloudflare-login-and-fleet-vpn/design.md#decision-3
#
# Self-test of tillandsias-fake-cloudflare, the fake Cloudflare every fixture
# in the cloudflare-login-and-fleet-vpn milestone (1505-sm2j) runs against
# instead of the real App. No network call in this script ever leaves
# 127.0.0.1, and no credential is used anywhere.
#
# Arms (each MUST appear below by name; a filter that matches zero tests
# would print "0 passed" and exit 0, which is not a pass, so this script
# asserts on named per-arm output rather than trusting an aggregate rc):
#   1 wrong_verifier_refused            - a code_verifier that does not hash
#                                          to the stored challenge is refused
#                                          400 invalid_grant
#   2 code_single_use_refused           - exchanging the same code twice is
#                                          refused the second time
#   3 redirect_uri_trailing_slash_refused - a redirect_uri differing only by
#                                          a trailing slash from the one used
#                                          at /oauth2/auth is refused
#   4 refresh_rotates_and_invalidates_old - grant_type=refresh_token returns
#                                          a new access/refresh pair and the
#                                          old refresh_token no longer works
#   5 ledger_records_calls_in_order     - the ledger after one login plus one
#                                          "fleet-vpn init"-shaped run of API
#                                          calls lists every call, in order,
#                                          with method and path
#
# NEGATIVE CONTROL (not an arm, a control on arm 1): re-run the wrong-verifier
# request against a second server started with
# TILLANDSIAS_FAKE_CLOUDFLARE_LAX=1, which disables the code_verifier check.
# If arm 1's rejection were not actually gated by the check it claims to
# test (e.g. it always fails the request for some other reason), this run
# would ALSO be refused, and the control would report FAIL — proving arm 1
# reaches the check it claims to test.
#
# PRE-FIX RESULT: FAILS — neither the binary nor this script exists on
# today's tree ("no such binary or script").
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_NAME="tillandsias-fake-cloudflare"
WORK="$(mktemp -d -t tillandsias-fake-cloudflare-test.XXXXXX)"

SERVER_PIDS=()
cleanup() {
    local pid
    for pid in "${SERVER_PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1
    done
    for pid in "${SERVER_PIDS[@]:-}"; do
        [ -n "$pid" ] && wait "$pid" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

if ! command -v cargo >/dev/null 2>&1; then
    echo "skip:fake-cloudflare:no-cargo"
    exit 3
fi

echo "[fake-cloudflare] building $BIN_NAME..." >&2
if ! (cd "$ROOT" && cargo build -p tillandsias-headless --bin "$BIN_NAME") >"$WORK/build.log" 2>&1; then
    cat "$WORK/build.log" >&2
    echo "fail:fake-cloudflare:build"
    exit 1
fi
BIN_PATH="$ROOT/target/debug/$BIN_NAME"
if [ ! -x "$BIN_PATH" ]; then
    echo "fail:fake-cloudflare:binary-missing:$BIN_PATH"
    exit 1
fi

# start_server <name> [lax]
# Starts a fresh instance with its own ledger, setting the globals SS_PORT
# and SS_LEDGER on success. Called directly (never inside $(...)) so the PID
# it records into SERVER_PIDS lands in THIS shell, not a subshell's copy —
# a command-substitution call would background the server from a subshell
# whose exit does not kill it, and the cleanup trap would never find it.
start_server() {
    local name="$1" lax="${2:-}"
    local port_out="$WORK/$name.port"
    local log="$WORK/$name.log"
    SS_LEDGER="$WORK/$name.ledger.jsonl"
    SS_PORT=""
    : >"$port_out"
    if [ "$lax" = "lax" ]; then
        TILLANDSIAS_FAKE_CLOUDFLARE_LAX=1 "$BIN_PATH" --ledger "$SS_LEDGER" >"$port_out" 2>"$log" &
    else
        "$BIN_PATH" --ledger "$SS_LEDGER" >"$port_out" 2>"$log" &
    fi
    local pid=$!
    SERVER_PIDS+=("$pid")
    local tries=0
    while [ ! -s "$port_out" ] && [ "$tries" -lt 100 ]; do
        sleep 0.05
        tries=$((tries + 1))
    done
    SS_PORT="$(head -n1 "$port_out" | tr -d '[:space:]')"
    if [ -z "$SS_PORT" ]; then
        echo "fail:fake-cloudflare:$name:no-port" >&2
        cat "$log" >&2
        return 1
    fi
    return 0
}

# pkce_challenge <verifier> -> stdout: base64url(sha256(verifier)), no pad
pkce_challenge() {
    printf '%s' "$1" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# json_field <json> <field> -> stdout: the string value, or empty
json_field() {
    printf '%s' "$1" | grep -oE "\"$2\":\"[^\"]*\"" | head -n1 | cut -d'"' -f4
}

# authorize <base> <redirect_uri> <state> <challenge> -> stdout: the code
authorize() {
    local base="$1" redirect_uri="$2" state="$3" challenge="$4"
    local loc
    loc="$(curl -s -o /dev/null -D - -G "$base/oauth2/auth" \
        --data-urlencode "response_type=code" \
        --data-urlencode "client_id=fake-client" \
        --data-urlencode "redirect_uri=$redirect_uri" \
        --data-urlencode "state=$state" \
        --data-urlencode "code_challenge=$challenge" \
        --data-urlencode "code_challenge_method=S256" \
        --data-urlencode "auto=approve" | grep -i '^location:')"
    printf '%s\n' "$loc" | grep -oE 'code=[^&[:space:]]*' | head -n1 | cut -d= -f2
}

# token_request <base> <code> <redirect_uri> <verifier> -> stdout: "HTTP_CODE BODY"
token_request() {
    local base="$1" code="$2" redirect_uri="$3" verifier="$4"
    local body_file="$WORK/token_resp.$$.json"
    local http_code
    http_code="$(curl -s -o "$body_file" -w '%{http_code}' \
        --data-urlencode "grant_type=authorization_code" \
        --data-urlencode "code=$code" \
        --data-urlencode "redirect_uri=$redirect_uri" \
        --data-urlencode "code_verifier=$verifier" \
        "$base/oauth2/token")"
    printf '%s %s\n' "$http_code" "$(cat "$body_file")"
    rm -f "$body_file"
}

PASS=0
TOTAL=0
arm_ok() {
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo "ok:   $1"
}
arm_fail() {
    TOTAL=$((TOTAL + 1))
    echo "FAIL: $1 -- $2"
}

REDIRECT_URI="http://127.0.0.1:48631/tillandsias/cloudflare/callback"
VERIFIER="the-real-verifier-0123456789abcdefghijklmnop"
CHALLENGE="$(pkce_challenge "$VERIFIER")"

if ! start_server main; then
    echo "fail:fake-cloudflare:main-server-did-not-start"
    exit 1
fi
MAIN_PORT="$SS_PORT"
MAIN_LEDGER="$SS_LEDGER"
MAIN_BASE="http://127.0.0.1:$MAIN_PORT"

# --- Arm 1: wrong_verifier_refused ---
CODE1="$(authorize "$MAIN_BASE" "$REDIRECT_URI" "state-1" "$CHALLENGE")"
if [ -z "$CODE1" ]; then
    arm_fail "wrong_verifier_refused" "authorize produced no code"
else
    RESULT1="$(token_request "$MAIN_BASE" "$CODE1" "$REDIRECT_URI" "not-the-real-verifier")"
    CODE_HTTP1="${RESULT1%% *}"
    if [ "$CODE_HTTP1" = "400" ] && grep -q 'invalid_grant' <<<"$RESULT1"; then
        arm_ok "wrong_verifier_refused"
    else
        arm_fail "wrong_verifier_refused" "got: $RESULT1"
    fi
fi

# --- Arm 3: redirect_uri_trailing_slash_refused (same fresh code as arm1's
# code is now used; mint a fresh one) ---
CODE3="$(authorize "$MAIN_BASE" "$REDIRECT_URI" "state-3" "$CHALLENGE")"
if [ -z "$CODE3" ]; then
    arm_fail "redirect_uri_trailing_slash_refused" "authorize produced no code"
else
    RESULT3="$(token_request "$MAIN_BASE" "$CODE3" "${REDIRECT_URI}/" "$VERIFIER")"
    CODE_HTTP3="${RESULT3%% *}"
    if [ "$CODE_HTTP3" = "400" ] && grep -q 'invalid_grant' <<<"$RESULT3"; then
        arm_ok "redirect_uri_trailing_slash_refused"
    else
        arm_fail "redirect_uri_trailing_slash_refused" "got: $RESULT3"
    fi
fi

# --- Arm 2: code_single_use_refused ---
CODE2="$(authorize "$MAIN_BASE" "$REDIRECT_URI" "state-2" "$CHALLENGE")"
if [ -z "$CODE2" ]; then
    arm_fail "code_single_use_refused" "authorize produced no code"
else
    FIRST="$(token_request "$MAIN_BASE" "$CODE2" "$REDIRECT_URI" "$VERIFIER")"
    SECOND="$(token_request "$MAIN_BASE" "$CODE2" "$REDIRECT_URI" "$VERIFIER")"
    FIRST_HTTP="${FIRST%% *}"
    SECOND_HTTP="${SECOND%% *}"
    if [ "$FIRST_HTTP" = "200" ] && [ "$SECOND_HTTP" = "400" ] && grep -q 'invalid_grant' <<<"$SECOND"; then
        arm_ok "code_single_use_refused"
    else
        arm_fail "code_single_use_refused" "first: $FIRST | second: $SECOND"
    fi
fi

# --- Arm 4: refresh_rotates_and_invalidates_old ---
CODE4="$(authorize "$MAIN_BASE" "$REDIRECT_URI" "state-4" "$CHALLENGE")"
if [ -z "$CODE4" ]; then
    arm_fail "refresh_rotates_and_invalidates_old" "authorize produced no code"
else
    EXCHANGE4="$(token_request "$MAIN_BASE" "$CODE4" "$REDIRECT_URI" "$VERIFIER")"
    EXCHANGE4_BODY="${EXCHANGE4#* }"
    OLD_REFRESH="$(json_field "$EXCHANGE4_BODY" refresh_token)"
    OLD_ACCESS="$(json_field "$EXCHANGE4_BODY" access_token)"
    if [ -z "$OLD_REFRESH" ]; then
        arm_fail "refresh_rotates_and_invalidates_old" "no refresh_token from initial exchange: $EXCHANGE4"
    else
        REFRESH_BODY_FILE="$WORK/refresh_resp.json"
        REFRESH_HTTP="$(curl -s -o "$REFRESH_BODY_FILE" -w '%{http_code}' \
            --data-urlencode "grant_type=refresh_token" \
            --data-urlencode "refresh_token=$OLD_REFRESH" \
            "$MAIN_BASE/oauth2/token")"
        REFRESH_BODY="$(cat "$REFRESH_BODY_FILE")"
        NEW_REFRESH="$(json_field "$REFRESH_BODY" refresh_token)"
        NEW_ACCESS="$(json_field "$REFRESH_BODY" access_token)"

        REPLAY_BODY_FILE="$WORK/refresh_replay.json"
        REPLAY_HTTP="$(curl -s -o "$REPLAY_BODY_FILE" -w '%{http_code}' \
            --data-urlencode "grant_type=refresh_token" \
            --data-urlencode "refresh_token=$OLD_REFRESH" \
            "$MAIN_BASE/oauth2/token")"
        REPLAY_BODY="$(cat "$REPLAY_BODY_FILE")"

        if [ "$REFRESH_HTTP" = "200" ] \
            && [ -n "$NEW_REFRESH" ] && [ "$NEW_REFRESH" != "$OLD_REFRESH" ] \
            && [ -n "$NEW_ACCESS" ] && [ "$NEW_ACCESS" != "$OLD_ACCESS" ] \
            && [ "$REPLAY_HTTP" = "400" ] && grep -q 'invalid_grant' <<<"$REPLAY_BODY"; then
            arm_ok "refresh_rotates_and_invalidates_old"
        else
            arm_fail "refresh_rotates_and_invalidates_old" \
                "rotate: $REFRESH_HTTP $REFRESH_BODY | replay: $REPLAY_HTTP $REPLAY_BODY"
        fi
        rm -f "$REFRESH_BODY_FILE" "$REPLAY_BODY_FILE"
    fi
fi

# --- Arm 5: ledger_records_calls_in_order ---
if ! start_server ledger; then
    arm_fail "ledger_records_calls_in_order" "ledger server did not start"
else
    LEDGER_PORT="$SS_PORT"
    LEDGER_LEDGER="$SS_LEDGER"
    LEDGER_BASE="http://127.0.0.1:$LEDGER_PORT"
    LVERIFIER="ledger-run-verifier-0123456789abcdefghijklmno"
    LCHALLENGE="$(pkce_challenge "$LVERIFIER")"

    # "one login": discovery, authorize, token exchange.
    curl -sf "$LEDGER_BASE/.well-known/openid-configuration" >/dev/null
    LCODE="$(authorize "$LEDGER_BASE" "$REDIRECT_URI" "state-ledger" "$LCHALLENGE")"
    token_request "$LEDGER_BASE" "$LCODE" "$REDIRECT_URI" "$LVERIFIER" >/dev/null

    # "one init run": the Zero Trust API routes fleet-vpn init needs.
    curl -sf "$LEDGER_BASE/accounts" >/dev/null
    curl -sf -X POST -d '{"name":"macuahuitl"}' \
        "$LEDGER_BASE/accounts/0123456789abcdef0123456789abcdef/access/service_tokens" >/dev/null
    curl -sf -X DELETE \
        "$LEDGER_BASE/accounts/0123456789abcdef0123456789abcdef/access/service_tokens/tok-1" >/dev/null
    curl -sf -X POST -d '{"name":"tillandsias-vpn"}' \
        "$LEDGER_BASE/accounts/0123456789abcdef0123456789abcdef/teamnet/virtual_networks" >/dev/null
    curl -sf -X PUT -d '{}' \
        "$LEDGER_BASE/accounts/0123456789abcdef0123456789abcdef/devices/policy" >/dev/null
    curl -sf -X PUT -d '[]' \
        "$LEDGER_BASE/accounts/0123456789abcdef0123456789abcdef/devices/policy/exclude" >/dev/null
    curl -sf -X POST -d '{"name":"deny-all"}' \
        "$LEDGER_BASE/accounts/0123456789abcdef0123456789abcdef/gateway/rules" >/dev/null

    EXPECTED_ORDER="GET /.well-known/openid-configuration
GET /oauth2/auth
POST /oauth2/token
GET /accounts
POST /accounts/0123456789abcdef0123456789abcdef/access/service_tokens
DELETE /accounts/0123456789abcdef0123456789abcdef/access/service_tokens/tok-1
POST /accounts/0123456789abcdef0123456789abcdef/teamnet/virtual_networks
PUT /accounts/0123456789abcdef0123456789abcdef/devices/policy
PUT /accounts/0123456789abcdef0123456789abcdef/devices/policy/exclude
POST /accounts/0123456789abcdef0123456789abcdef/gateway/rules"

    if [ ! -f "$LEDGER_LEDGER" ]; then
        arm_fail "ledger_records_calls_in_order" "no ledger file at $LEDGER_LEDGER"
    else
        # One "METHOD path" line per ledger entry, query string dropped.
        # Plain awk (bash 3.2 / BSD userland; no python, 1087-h2z9). Each
        # ledger line is one serde_json object; inside a JSON string every
        # quote is escaped, so the unescaped `"method":"` / `"path":"` key
        # sequences can only be the keys themselves, never body text.
        ACTUAL_ORDER="$(awk '
            NF == 0 { next }
            {
                m = $0; sub(/.*"method":"/, "", m); sub(/".*/, "", m)
                p = $0; sub(/.*"path":"/, "", p); sub(/".*/, "", p); sub(/[?].*/, "", p)
                print m " " p
            }' "$LEDGER_LEDGER")"
        LINE_COUNT="$(wc -l <"$LEDGER_LEDGER" | tr -d '[:space:]')"
        if [ "$ACTUAL_ORDER" = "$EXPECTED_ORDER" ] && [ "$LINE_COUNT" = "10" ]; then
            arm_ok "ledger_records_calls_in_order"
        else
            arm_fail "ledger_records_calls_in_order" "expected 10 lines in order; got ($LINE_COUNT lines): $ACTUAL_ORDER"
        fi
    fi
fi

echo ""
echo "-- negative control: LAX disables the verifier check arm 1 depends on --"
CONTROL_OK=0
if ! start_server laxcontrol lax; then
    echo "FAIL: negative_control_lax_makes_wrong_verifier_succeed -- lax server did not start"
else
    LAX_PORT="$SS_PORT"
    LAX_BASE="http://127.0.0.1:$LAX_PORT"
    LAX_VERIFIER="lax-real-verifier-0123456789abcdefghijklmnop"
    LAX_CHALLENGE="$(pkce_challenge "$LAX_VERIFIER")"
    LAX_CODE="$(authorize "$LAX_BASE" "$REDIRECT_URI" "state-lax" "$LAX_CHALLENGE")"
    LAX_RESULT="$(token_request "$LAX_BASE" "$LAX_CODE" "$REDIRECT_URI" "definitely-not-the-real-verifier")"
    LAX_HTTP="${LAX_RESULT%% *}"
    if [ "$LAX_HTTP" = "200" ]; then
        echo "ok:   negative_control_lax_makes_wrong_verifier_succeed (proves arm 1 exercises the check)"
        CONTROL_OK=1
    else
        echo "FAIL: negative_control_lax_makes_wrong_verifier_succeed -- LAX run still refused ($LAX_RESULT); arm 1 may not be gated by the check it claims to test"
    fi
fi

echo ""
if [ "$PASS" -eq "$TOTAL" ] && [ "$TOTAL" -eq 5 ] && [ "$CONTROL_OK" -eq 1 ]; then
    echo "ok:fake-cloudflare:${PASS}/${TOTAL}+control"
    exit 0
else
    echo "fail:fake-cloudflare:${PASS}/${TOTAL}+control=${CONTROL_OK}"
    exit 1
fi
