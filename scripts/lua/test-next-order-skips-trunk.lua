-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:2152-u7s4
--
-- test-next-order-skips-trunk.lua — `next-order` never mints a prefix trunk
-- already carries, even when this checkout's fold is behind trunk.
--
-- WHY (yoga, 2026-11-21): next-order minted 2149 after 2149-3zy5 had landed.
-- The mint read only the local fold; a checkout that had not merged trunk saw
-- 2148 as the highest prefix. The fix reads trunk's fragment NAMES too.
--
-- Arms:
--   1  a checkout behind trunk (local max 10, trunk carries 20) mints 21
--      (RED before 2152-u7s4: it minted 11)
--   2  it says on stderr that trunk was above the checkout
--   3  an explicit prefix is honoured unchanged
--   4  no trunk ref (TILLANDSIAS_NEXT_ORDER_TRUNK names nothing) -> local answer, 11
--
-- Verdict: ok:next-order-skips-trunk:<n> arms | violation:next-order-skips-trunk:<n>-failed
local fixture = require "common.fixture"
local T = fixture.new("next-order-skips-trunk")

local BIN = env.get("TILLANDSIAS_PLAN_BIN")
if BIN == nil or BIN == "" then BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if BIN == nil or BIN == "" then verdict.blocked("next-order-skips-trunk", "no plan binary (set TILLANDSIAS_PLAN_BIN)") end

local W = T:scratch("work")
local O = T:scratch("origin")
local X = T:scratch("other")
local GIT = { "-c", "user.name=t", "-c", "user.email=t@t" }
local function g(dir, ...)
    local argv = { "git", "-C", dir }
    for _, a in ipairs(GIT) do argv[#argv + 1] = a end
    for _, a in ipairs{ ... } do argv[#argv + 1] = a end
    T:must(argv)
end

fs.mkdir(W.rel .. "/plan/index.d")
fs.write(W.rel .. "/plan/index.d/.keep", "")
fs.write(W.rel .. "/plan/index.yaml",
    "packets:\n  - packet_id: a\n    order: \"10-aaaa\"\n    status: ready\n    title: a\n")
T:must{ "git", "init", "-q", "-b", "linux-next", W.abs }
g(W.abs, "add", "-A"); g(W.abs, "commit", "-qm", "base")
T:must{ "git", "init", "-q", "--bare", O.abs }
g(W.abs, "remote", "add", "origin", O.abs)
g(W.abs, "push", "-q", "origin", "linux-next")
-- Another host lands order 20 on trunk; this checkout only FETCHES it.
T:must{ "git", "clone", "-q", "-b", "linux-next", O.abs, X.abs }
fs.mkdir(X.rel .. "/plan/index.d")
fs.write(X.rel .. "/plan/index.d/20260101t000000z-20-bbbb-other-host.yaml",
    "packets:\n  - packet_id: b\n    order: \"20-bbbb\"\n    status: ready\n    title: b\n")
-- An EVENT fragment whose 8-digit hash looks like an order (a 4-letter host):
-- it must not be read as prefix 33163463 (found on the real trunk).
fs.write(X.rel .. "/plan/index.d/20260928t130215z-33163463-yoga-silverblue.yaml", "events: []\n")
g(X.abs, "add", "-A"); g(X.abs, "commit", "-qm", "other host files 20")
g(X.abs, "push", "-q", "origin", "linux-next")
g(W.abs, "fetch", "-q", "origin")

local function mint(args, extra)
    local argv = { BIN, "next-order" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    argv.cwd = W.abs; argv.env = extra or {}
    local r = T:run(argv)
    local tok = text.trim((r.stdout or ""):match("^[^\n]*") or "")
    return tok, r
end

local tok, r = mint({})
T:arm("a checkout behind trunk mints above trunk's highest prefix (21, not 11)",
    r.code == 0 and tok:match("^21%-%w%w%w%w$") ~= nil, "token=[" .. tok .. "] err=[" .. (r.stderr or "") .. "]")
T:arm("it says trunk was above the checkout",
    (r.stderr or ""):find("carries prefix 20", 1, true) ~= nil, r.stderr or "")
tok, r = mint({ "500" })
T:arm("an explicit prefix is honoured", r.code == 0 and tok:match("^500%-") ~= nil, tok)
tok, r = mint({}, { TILLANDSIAS_NEXT_ORDER_TRUNK = "refs/heads/no-such-trunk" })
T:arm("no readable trunk -> the local answer (11)", r.code == 0 and tok:match("^11%-") ~= nil, tok)

T:finish()
