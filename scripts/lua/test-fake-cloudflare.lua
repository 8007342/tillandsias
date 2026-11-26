-- @env PATH HOME CARGO_TARGET_DIR
-- @trace order:1505-svve, order:2387-b6v2
--
-- test-fake-cloudflare.lua — self-test of tillandsias-fake-cloudflare, the fake Cloudflare every
-- cloudflare-login-and-fleet-vpn fixture runs against. Ported from the .sh of the same name
-- (2387-b6v2). Every request is loopback (curl --noproxy '*' to 127.0.0.1); no credential is used.
--
--   1 wrong_verifier_refused               a code_verifier not hashing to the challenge: 400 invalid_grant
--   2 code_single_use_refused              the same code exchanged twice: 200, then 400 invalid_grant
--   3 redirect_uri_trailing_slash_refused  a redirect_uri differing by a trailing slash: 400 invalid_grant
--   4 refresh_rotates_and_invalidates_old  refresh returns a new pair and the old refresh_token is refused
--   5 ledger_records_calls_in_order        one login + one fleet-vpn-init run: 10 ledger lines, in order
--   CONTROL (on arm 1) a TILLANDSIAS_FAKE_CLOUDFLARE_LAX=1 server accepts the wrong verifier (200),
--           so arm 1's refusal is the verifier check and nothing else.
--
-- Every server is a proc.spawn handle whose shell execs the binary (the handle's pid is the server)
-- and is killed by its handle at the end, on every path that reaches T:finish or T:refuse.
--
-- Usage: tillandsias-plan script run scripts/lua/test-fake-cloudflare.lua
-- Verdict: ok:fake-cloudflare:<n> arms | violation:... | skip:...:no-cargo, no-linker, no-curl, no-openssl

local fixture = require "common.fixture"
local T = fixture.new("fake-cloudflare")
local SH = fixture.posix_shell()
if not fixture.which("curl") then T:skip("no-curl") end
if not fixture.which("openssl") then T:skip("no-openssl") end
local C = require("common.cargotest").new(T)
local FAKE = C:build("tillandsias-headless", "tillandsias-fake-cloudflare")
local w = T:scratch()

local servers = {}
local function stop_all()
    for _, h in ipairs(servers) do pcall(function() h:kill() end) end
    servers = {}
end
local refuse = T.refuse
function T:refuse(...) stop_all(); return refuse(self, ...) end

local function start(name, lax)
    local port, log = w.abs .. "/" .. name .. ".port", w.abs .. "/" .. name .. ".log"
    local ledger = w.abs .. "/" .. name .. ".ledger.jsonl"
    fs.write(w.rel .. "/" .. name .. ".port", "")
    local h = proc.spawn{ argv = { SH, "-s", "--", FAKE, ledger, port, log },
        stdin = 'exec "$1" --ledger "$2" >"$3" 2>"$4" </dev/null\n',
        env_unset = { "TILLANDSIAS_*" }, env = lax and { TILLANDSIAS_FAKE_CLOUDFLARE_LAX = "1" } or nil,
        timeout_ms = 600000 }
    servers[#servers + 1] = h
    local p = ""
    for _ = 1, 100 do
        p = text.trim(fs.read(w.rel .. "/" .. name .. ".port"))
        if p ~= "" then break end
        T:run{ "sleep", "0.05" }
    end
    if p == "" then return nil end
    return { base = "http://127.0.0.1:" .. p:match("^[^\n]*"), ledger = w.rel .. "/" .. name .. ".ledger.jsonl" }
end

local function curl(args)
    local a = { "curl", "-s", "--noproxy", "*" }
    for _, v in ipairs(args) do a[#a + 1] = v end
    return T:run{ table.unpack(a) }
end
local function challenge(v)
    local r = T:run{ SH, "-s", "--", v, stdin = "printf '%s' \"$1\" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '='\n" }
    return text.trim(r.stdout or "")
end
local function authorize(base, redirect, state, ch)
    local r = curl{ "-o", "/dev/null", "-D", "-", "-G", base .. "/oauth2/auth",
        "--data-urlencode", "response_type=code", "--data-urlencode", "client_id=fake-client",
        "--data-urlencode", "redirect_uri=" .. redirect, "--data-urlencode", "state=" .. state,
        "--data-urlencode", "code_challenge=" .. ch, "--data-urlencode", "code_challenge_method=S256",
        "--data-urlencode", "auto=approve" }
    for l in (r.stdout or ""):gmatch("[^\r\n]+") do
        if l:lower():find("^location:") then return l:match("code=([^&%s]*)") end
    end
    return nil
end
-- POST to /oauth2/token: {http=, body=}.
local function token(base, fields)
    local a = { "-w", "\n%{http_code}" }
    for _, f in ipairs(fields) do a[#a + 1] = "--data-urlencode"; a[#a + 1] = f end
    a[#a + 1] = base .. "/oauth2/token"
    local o = curl(a).stdout or ""
    local body, http = o:match("^(.*)\n(%d+)$")
    return { http = http or "", body = body or o, s = (http or "?") .. " " .. (body or o) }
end
local function exchange(base, code, redirect, verifier)
    return token(base, { "grant_type=authorization_code", "code=" .. code, "redirect_uri=" .. redirect, "code_verifier=" .. verifier })
end
local function field(body, k) return body:match('"' .. k .. '":"([^"]*)"') end
local function refused(x) return x.http == "400" and text.contains(x.body, "invalid_grant") end

local REDIRECT = "http://127.0.0.1:48631/tillandsias/cloudflare/callback"
local VERIFIER = "the-real-verifier-0123456789abcdefghijklmnop"
local CH = challenge(VERIFIER)
if CH == "" then T:refuse("setup-failed", "openssl produced no challenge") end
local main = start("main")
if not main then T:refuse("setup-failed", "main server did not start") end
local B = main.base

local c1 = authorize(B, REDIRECT, "state-1", CH)
local x = c1 and exchange(B, c1, REDIRECT, "not-the-real-verifier")
T:arm("1 wrong_verifier_refused", x and refused(x), x and x.s or "authorize produced no code")

local c3 = authorize(B, REDIRECT, "state-3", CH)
x = c3 and exchange(B, c3, REDIRECT .. "/", VERIFIER)
T:arm("3 redirect_uri_trailing_slash_refused", x and refused(x), x and x.s or "authorize produced no code")

local c2 = authorize(B, REDIRECT, "state-2", CH)
local first = c2 and exchange(B, c2, REDIRECT, VERIFIER)
local second = c2 and exchange(B, c2, REDIRECT, VERIFIER)
T:arm("2 code_single_use_refused", c2 and first.http == "200" and refused(second),
    c2 and ("first: " .. first.s .. " | second: " .. second.s) or "authorize produced no code")

local c4 = authorize(B, REDIRECT, "state-4", CH)
local e4 = c4 and exchange(B, c4, REDIRECT, VERIFIER)
local old_r, old_a = e4 and field(e4.body, "refresh_token"), e4 and field(e4.body, "access_token")
if not old_r or old_r == "" then
    T:arm("4 refresh_rotates_and_invalidates_old", false, "no refresh_token from initial exchange: " .. (e4 and e4.s or "no code"))
else
    local rot = token(B, { "grant_type=refresh_token", "refresh_token=" .. old_r })
    local new_r, new_a = field(rot.body, "refresh_token"), field(rot.body, "access_token")
    local replay = token(B, { "grant_type=refresh_token", "refresh_token=" .. old_r })
    T:arm("4 refresh_rotates_and_invalidates_old", rot.http == "200" and new_r and new_r ~= "" and new_r ~= old_r
        and new_a and new_a ~= "" and new_a ~= old_a and refused(replay), "rotate: " .. rot.s .. " | replay: " .. replay.s)
end

local L = start("ledger")
if not L then
    T:arm("5 ledger_records_calls_in_order", false, "ledger server did not start")
else
    local LB, LV = L.base, "ledger-run-verifier-0123456789abcdefghijklmno"
    local ACC = "/accounts/0123456789abcdef0123456789abcdef"
    curl{ "-f", "-o", "/dev/null", LB .. "/.well-known/openid-configuration" }
    local lc = authorize(LB, REDIRECT, "state-ledger", challenge(LV))
    exchange(LB, lc or "", REDIRECT, LV)
    curl{ "-f", "-o", "/dev/null", LB .. "/accounts" }
    curl{ "-f", "-o", "/dev/null", "-X", "POST", "-d", '{"name":"macuahuitl"}', LB .. ACC .. "/access/service_tokens" }
    curl{ "-f", "-o", "/dev/null", "-X", "DELETE", LB .. ACC .. "/access/service_tokens/tok-1" }
    curl{ "-f", "-o", "/dev/null", "-X", "POST", "-d", '{"name":"tillandsias-vpn"}', LB .. ACC .. "/teamnet/virtual_networks" }
    curl{ "-f", "-o", "/dev/null", "-X", "PUT", "-d", "{}", LB .. ACC .. "/devices/policy" }
    curl{ "-f", "-o", "/dev/null", "-X", "PUT", "-d", "[]", LB .. ACC .. "/devices/policy/exclude" }
    curl{ "-f", "-o", "/dev/null", "-X", "POST", "-d", '{"name":"deny-all"}', LB .. ACC .. "/gateway/rules" }
    local want = table.concat({ "GET /.well-known/openid-configuration", "GET /oauth2/auth", "POST /oauth2/token",
        "GET /accounts", "POST " .. ACC .. "/access/service_tokens", "DELETE " .. ACC .. "/access/service_tokens/tok-1",
        "POST " .. ACC .. "/teamnet/virtual_networks", "PUT " .. ACC .. "/devices/policy",
        "PUT " .. ACC .. "/devices/policy/exclude", "POST " .. ACC .. "/gateway/rules" }, "\n")
    if not fs.exists(L.ledger) then
        T:arm("5 ledger_records_calls_in_order", false, "no ledger file at " .. L.ledger)
    else
        local got, n = {}, 0
        for l in fs.read(L.ledger):gmatch("([^\n]*)\n") do
            n = n + 1
            if l:find("%S") then
                got[#got + 1] = (l:match('"method":"([^"]*)"') or "?") .. " " .. ((l:match('"path":"([^"]*)"') or "?"):gsub("%?.*", ""))
            end
        end
        local actual = table.concat(got, "\n")
        T:arm("5 ledger_records_calls_in_order", actual == want and n == 10, "(" .. n .. " lines): " .. actual)
    end
end

local lax = start("laxcontrol", true)
if not lax then
    T:arm("CONTROL lax server makes the wrong verifier succeed", false, "lax server did not start")
else
    local LXV = "lax-real-verifier-0123456789abcdefghijklmnop"
    local lcode = authorize(lax.base, REDIRECT, "state-lax", challenge(LXV))
    local lx = exchange(lax.base, lcode or "", REDIRECT, "definitely-not-the-real-verifier")
    T:arm("CONTROL lax server makes the wrong verifier succeed (arm 1 reaches the check)", lx.http == "200",
        "LAX run still refused: " .. lx.s)
end

stop_all()
T:finish()
