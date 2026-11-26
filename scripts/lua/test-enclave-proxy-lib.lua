-- @env PATH HOME TILLANDSIAS_ENCLAVE_PROXY_LIB TILLANDSIAS_HEADLESS_MAIN
-- @trace order:923-rmtw, order:801-kqme, order:883-ncrs, order:2387-b6v2
--
-- test-enclave-proxy-lib.lua — scripts/lib/enclave-proxy.sh carries the same no_proxy list and
-- default subnet as crates/tillandsias-headless/src/main.rs, composes them as enclave_no_proxy()
-- does, and no other script re-pastes the list. Ported from the .sh of the same name (2387-b6v2).
--
--   1 base list = ENCLAVE_NO_PROXY_BASE   2 default subnet = DEFAULT_ENCLAVE_SUBNET
--   3 the composed list appends the subnet   4 TILLANDSIAS_ENCLAVE_SUBNET overrides it
--   5 the env-arg array has six flag pairs   6 its no_proxy value is the composed list
--   7 nix-cache is present (801-kqme)   8 git-service is absent   9 no script re-pastes the list
--
-- Usage: tillandsias-plan script run scripts/lua/test-enclave-proxy-lib.lua
-- Verdict: ok:enclave-proxy-lib:<n> arms | violation:... | unavailable:...

local fixture = require "common.fixture"
-- Git's own bash on native Windows, never WSL's (2246-fkea).
local BASH = fixture.posix_shell()
local T = fixture.new("enclave-proxy-lib")
local ROOT = fixture.repo_root()
local function opt(k, d) local v = env.get(k); return (v and v ~= "") and v or d end
local LIB = opt("TILLANDSIAS_ENCLAVE_PROXY_LIB", ROOT .. "/scripts/lib/enclave-proxy.sh")
local MAIN = opt("TILLANDSIAS_HEADLESS_MAIN", ROOT .. "/crates/tillandsias-headless/src/main.rs")
local function slurp(p) local r = T:run{ "cat", p }; return r.code == 0 and r.stdout or nil end
local lib_src, main_src = slurp(LIB), slurp(MAIN)
if not lib_src then verdict.emit("unavailable:enclave-proxy-lib-unreadable:" .. LIB, 2) end
if not main_src then verdict.emit("unavailable:headless-source-unreadable:" .. MAIN, 2) end
-- The first string literal at or after the const line (it may wrap onto the next line).
local base = ("\n" .. main_src):match('\nconst ENCLAVE_NO_PROXY_BASE: &str =[^"]-"([^"]+)"')
local subnet = ("\n" .. main_src):match('\nconst DEFAULT_ENCLAVE_SUBNET: &str =[^"\n]*"([^"]*)"')
if not base or not subnet or subnet == "" then
    verdict.emit("unavailable:cannot-parse-rust-constants (base='" .. tostring(base) .. "' subnet='" .. tostring(subnet) .. "')", 2)
end
-- The lib is bash (it builds an array), so bash sources it; one value per line.
local DUMP = [[. "$1" || exit 9
printf '%s\n' "$ENCLAVE_NO_PROXY_BASE" "$ENCLAVE_SUBNET_DEFAULT" "$ENCLAVE_NO_PROXY" "${#ENCLAVE_PROXY_ENV_ARGS[@]}" "${ENCLAVE_PROXY_ENV_ARGS[9]}"
]]
local function dump(extra)
    local e = { PATH = env.get("PATH"), HOME = env.get("HOME") }
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = proc.run{ argv = { BASH, "-s", "--", LIB }, stdin = DUMP, env = e, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000 }
    local v = {}
    for l in ((r.stdout or "") .. "\n"):gmatch("([^\n]*)\n") do v[#v + 1] = l end
    return v, r
end
local v, r = dump()
if r.code ~= 0 then T:refuse("lib-did-not-source", (r.stderr or ""):sub(1, 300)) end
out.line("enclave-proxy-lib: 923-rmtw")
local function eq(name, want, got) T:arm(name, want == got, "expected [" .. tostring(want) .. "] actual [" .. tostring(got) .. "]") end
eq("the lib's base list equals ENCLAVE_NO_PROXY_BASE", base, v[1])
eq("the lib's default subnet equals DEFAULT_ENCLAVE_SUBNET", subnet, v[2])
eq("the composed list appends the subnet, as enclave_no_proxy() does", base .. "," .. subnet, v[3])
eq("TILLANDSIAS_ENCLAVE_SUBNET overrides the subnet", base .. ",10.9.9.0/24", dump{ TILLANDSIAS_ENCLAVE_SUBNET = "10.9.9.0/24" }[3])
eq("the env-arg array carries the six proxy flags", "12", v[4])
eq("the array's no_proxy value is the composed list", "no_proxy=" .. base .. "," .. subnet, v[5])
local list = "," .. (v[3] or "") .. ","
T:arm("nix-cache is present (801-kqme)", text.contains(list, ",nix-cache,"), "nix-cache missing — this is the 883-ncrs symptom set")
T:arm("git-service is absent, as in the Rust list", not text.contains(list, ",git-service,"), "git-service is back — the Rust list dropped it")
-- Every shell script that carries the literal list, but the lib and the proxy-env checker.
local g = T:run{ "grep", "-rlF", "no_proxy=localhost", ROOT .. "/scripts", "--include=*.sh" }
local copies = {}
for f in (g.stdout or ""):gmatch("[^\n]+") do
    if not f:find("scripts/lib/enclave-proxy.sh", 1, true) and not f:find("scripts/check-containers-conf-proxy-env.sh", 1, true) then
        copies[#copies + 1] = f
    end
end
T:arm("no script re-pastes the list", g.code <= 1 and #copies == 0, "a script re-pastes the no_proxy list instead of sourcing the lib: " .. table.concat(copies, " "))
T:finish()
