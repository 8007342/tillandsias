-- @trace order:900-z3kv, order:1149-vgn2, order:1903-djsq, order:2353-ccsd
-- @env PATH HOME
--
-- test-credential-cold-state-probe.lua — the credential cold-state probe must never turn
-- "I could not ask" into "the room was clean", on Linux or on darwin. Ported from
-- test-credential-cold-state-probe.sh (2353-ccsd), with the darwin arms the .sh could not
-- have: the probe answered could-not-run:no-busctl on every Mac (v56.11.24.1 smoke, finding 4).
--
-- NO ARM REACHES A REAL SESSION BUS (1903-djsq). Every probe run gets
-- DBUS_SESSION_BUS_ADDRESS pointing at a socket that does not exist, so on a Linux host the
-- real-busctl arms (5, 6) can only reach nothing. The platform arms run the probe with
-- `uname` stubbed, so the Linux and darwin paths are both driven on every host, with stubbed
-- busctl/security. No arm writes or reads anything resembling a secret.
--
--   1  the source never materialises a secret: no `secret-tool search`, and `security`
--      is never called with -g or -w
--   2  the keychain schema matches vault_bootstrap.rs (KEYCHAIN_SERVICE, VAULT_SHAMIR_SHARE_V1)
--   3  linux, no busctl on PATH: could-not-run, says NOT a cold verdict, exit 3
--   4  darwin, no security on PATH: could-not-run, NOT cold, exit 3
--   5  five consecutive runs on this host agree (no pipeline race decides the verdict)
--   6  the md form agrees with the line form (a named skip of the arm when could-not-run)
--   7  linux, an empty keychain with a fallback share is WARM (1149-vgn2)
--   8  linux CONTROL, the same keychain with no fallback is COLD
--   9  darwin, no Keychain item (security exit 44) is COLD; with a fallback, WARM
--  10  darwin, an item present is WARM with its creation date, and the stub saw no -g/-w
--
-- GRAMMAR ok:credential-cold-state-probe:<n> arms | violation:credential-cold-state-probe:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("credential-cold-state-probe")
local ROOT = fixture.repo_root()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary", "build one: cargo build --release -p tillandsias-plan") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local PROBE = "scripts/lua/probe-credential-cold-state.lua"
local SRC = fs.read(PROBE)
local W = T:scratch()
local NOBUS = "unix:path=" .. W.abs .. "/no-such-bus"

-- 1 — on the source, comments stripped: "it printed no secret here today" is not the claim.
local code = {}
for l in (SRC .. "\n"):gmatch("([^\n]*)\n") do code[#code + 1] = (l:gsub("%-%-.*$", "")) end
code = table.concat(code, "\n")
local sec_calls, bad_flag = 0, false
for c in code:gmatch("security find%-generic%-password[^\n']*") do
    sec_calls = sec_calls + 1
    if c:find(" %-g") or c:find(" %-w") then bad_flag = true end
end
T:arm("1 the probe never calls secret-tool search, and calls security without -g/-w",
    not code:find("secret%-tool%s+search") and sec_calls > 0 and not bad_flag, "secret-tool or a password flag found; security calls=" .. sec_calls)

-- 2 — a wrong query and an absent secret look identical from outside.
local vb = fs.read("crates/tillandsias-headless/src/vault_bootstrap.rs")
local svc = vb:match('const KEYCHAIN_SERVICE[^=]*=%s*"([^"]*)"')
local att = vb:match('const VAULT_SHAMIR_SHARE_V1[^=]*=%s*"([^"]*)"')
T:arm("2 the probe's keychain schema matches vault_bootstrap.rs",
    svc ~= nil and att ~= nil and text.contains(SRC, 'KEYCHAIN_SERVICE = "' .. svc .. '"') and text.contains(SRC, 'SHARE_ATTR = "' .. att .. '"'),
    "vault_bootstrap.rs says " .. tostring(svc) .. " / " .. tostring(att))

-- A PATH of symlinks to the tools the probe's shell needs, plus stubs. Built, not
-- narrowed: /usr/bin holds busctl on some hosts, and a narrowed PATH would still find it.
local function bin(name, stubs)
    local d = W.rel .. "/" .. name
    fs.mkdir(d)
    T:must{ fixture.posix_shell(), "-s", "--", W.abs .. "/" .. name, stdin = [[
for t in bash sh cat date cut tr head printf sort sed awk grep; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$1/$t"
done]] }
    for tool, body in pairs(stubs) do
        fs.write(d .. "/" .. tool, "#!/bin/bash\n" .. body .. "\n")
        T:must{ "chmod", "+x", W.abs .. "/" .. name .. "/" .. tool }
    end
    return W.abs .. "/" .. name
end
local function probe(path, cache, fmt)
    local argv = { PLAN, "script", "run", PROBE }
    if fmt then argv[#argv + 1] = "--"; argv[#argv + 1] = "--format=" .. fmt end
    local e = { DBUS_SESSION_BUS_ADDRESS = NOBUS, XDG_CACHE_HOME = cache or (W.abs .. "/empty-cache") }
    if path then e.PATH = path end
    argv.cwd, argv.env, argv.env_unset, argv.timeout_ms = ROOT, e, { "TILLANDSIAS_*" }, 60000
    local r = T:run(argv)
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local LINUX, DARWIN = "echo Linux", "echo Darwin"

-- 3 — linux, no busctl.
local p = bin("linux-nobus", { uname = LINUX })
local rc, o = probe(p)
T:arm("3 linux with no busctl is could-not-run, says it is NOT cold, and exits 3",
    rc == 3 and text.contains(o, "could-not-run:credential-state:no-busctl") and text.contains(o, "NOT a cold verdict")
        and not text.contains(o, "credential-state:cold"), "rc=" .. tostring(rc) .. " " .. o)

-- 4 — darwin, no security.
p = bin("darwin-nosec", { uname = DARWIN })
rc, o = probe(p)
T:arm("4 darwin with no security is could-not-run, NOT cold, exit 3",
    rc == 3 and text.contains(o, "could-not-run:credential-state:no-security") and not text.contains(o, "credential-state:cold"),
    "rc=" .. tostring(rc) .. " " .. o)

-- 5 — this host's real state, five times.
local seen, n = {}, 0
for _ = 1, 5 do
    local _, v = probe(nil)
    v = v:match("[%w-]+:credential%-state:[%w-]+") or ("unclassified:" .. v:sub(1, 80))
    if not seen[v] then seen[v] = true; n = n + 1 end
end
local list = {}
for k in pairs(seen) do list[#list + 1] = k end
T:arm("5 five consecutive runs on this host agree", n == 1, "verdicts: " .. table.concat(list, " "))

-- 6 — the md block names the same verdict the line does.
local _, line = probe(nil)
local kind = line:match("ok:credential%-state:(%a+)")
if not kind then
    out.line("skip: 6 this host's verdict is could-not-run; the md form has no verdict to compare (" .. line:match("^[^\n]*") .. ")")
else
    local _, md = probe(nil, nil, "md")
    T:arm("6 the md form reports the same verdict as the line form", text.contains(md, "`credential-" .. kind .. "`")
        and text.contains(md, "ok:credential-state:" .. kind), kind .. " vs " .. md)
end

-- 7, 8 — linux: an empty keychain (a stub that answers, with no items) and a fallback share.
local LBUS = 'case "$*" in *list*) echo "org.freedesktop.secrets 1 dummy - - -" ;; *call*) echo "ao 0 ao 0" ;; esac; exit 0'
p = bin("linux-empty", { uname = LINUX, busctl = LBUS })
local cache = W.rel .. "/cache"
fs.mkdir(cache .. "/tillandsias")
fs.write(cache .. "/tillandsias/fallback_vault-shamir-share-v1", "")
rc, o = probe(p, W.abs .. "/cache")
T:arm("7 linux: an empty keychain with a fallback share reads WARM, naming the fallback",
    rc == 0 and text.contains(o, "ok:credential-state:warm") and text.contains(o, "fallback share present"), "rc=" .. tostring(rc) .. " " .. o)
T:must{ "rm", "-f", W.abs .. "/cache/tillandsias/fallback_vault-shamir-share-v1" }
rc, o = probe(p, W.abs .. "/cache")
T:arm("8 CONTROL linux: the same keychain with no fallback reads COLD", rc == 0 and text.contains(o, "ok:credential-state:cold"),
    "rc=" .. tostring(rc) .. " " .. o)

-- 9 — darwin: no item.
local ARGV = W.abs .. "/security-argv"
local NOITEM = 'printf "%s\\n" "$*" >> "' .. ARGV .. '"; echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; exit 44'
p = bin("darwin-noitem", { uname = DARWIN, security = NOITEM })
rc, o = probe(p, W.abs .. "/cache")
local cold = rc == 0 and text.contains(o, "ok:credential-state:cold") and text.contains(o, "macOS Keychain")
fs.write(cache .. "/tillandsias/fallback_vault-shamir-share-v1", "")
local rc2, o2 = probe(p, W.abs .. "/cache")
T:arm("9 darwin: no Keychain item is COLD; with a fallback share it is WARM",
    cold and rc2 == 0 and text.contains(o2, "ok:credential-state:warm") and text.contains(o2, "fallback share present"),
    "rc=" .. tostring(rc) .. " " .. o .. " | with fallback rc=" .. tostring(rc2) .. " " .. o2)
T:must{ "rm", "-f", W.abs .. "/cache/tillandsias/fallback_vault-shamir-share-v1" }

-- 10 — darwin: an item, attributes only.
local ITEM = 'printf "%s\\n" "$*" >> "' .. ARGV .. '"\ncat <<\'A\'\nkeychain: "/Users/x/Library/Keychains/login.keychain-db"\nclass: "genp"\nattributes:\n'
    .. '    "acct"<blob>="vault-shamir-share-v1"\n    "cdat"<timedate>=0x32303236313132353030353935325A00  "20261125005952Z\\000"\n'
    .. '    "mdat"<timedate>=0x32303236313132353030353935325A00  "20261125005952Z\\000"\n    "svce"<blob>="tillandsias"\nA\nexit 0'
p = bin("darwin-item", { uname = DARWIN, security = ITEM })
rc, o = probe(p, W.abs .. "/cache")
local argv_seen = fs.exists(W.rel .. "/security-argv") and fs.read(W.rel .. "/security-argv") or ""
local flagged = false
for l in argv_seen:gmatch("[^\n]+") do
    for w in l:gmatch("%S+") do if w == "-g" or w == "-w" then flagged = true end end
end
T:arm("10 darwin: an item present is WARM with its creation date, and security was never asked for the password",
    rc == 0 and text.contains(o, "ok:credential-state:warm") and text.contains(o, "created=2026-11-25T00:59:52Z")
        and argv_seen ~= "" and not flagged, "rc=" .. tostring(rc) .. " " .. o .. " argv=[" .. argv_seen .. "]")

T:finish()
