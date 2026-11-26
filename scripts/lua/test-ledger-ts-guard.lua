-- @env PATH HOME
-- @trace order:719-kgr5, order:784-dwkh, spec:methodology-accountability, order:2322-a756
--
-- test-ledger-ts-guard.lua — ledger writers refuse a timestamp that disagrees with the host
-- clock, and accept a measured one. Ported from the .sh of the same name (2322-a756); same
-- nine scenarios. THE BREACH: on the 2026-08-13 windows overnight run --ts was hand-authored
-- and drifted to +8.6 h, so that host's work sorted after later work and could outlive a
-- claim's TTL. Every write targets a scratch ledger; a refusal must write nothing.
--
-- Usage: tillandsias-plan script run scripts/lua/test-ledger-ts-guard.lua
-- Verdict: ok:ledger-ts-guard:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("ledger-ts-guard")
local SH, PLAN = fixture.posix_shell(), fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local d = T:scratch()
fs.mkdir(d.rel .. "/index.d")
fs.write(d.rel .. "/index.yaml", "packets:\n  - packet_id: fixture-packet\n    order: 000-test\n    status: ready\n"
    .. "    title: A packet that exists only for this fixture\n    kind: bug\n")

-- The clock plus n seconds, GNU then BSD: an empty stamp would test nothing (784-dwkh).
local function at(n)
    local r = T:must{ SH, "-s", "--", tostring(n), stdin = 'e=$(( $(date -u +%s) + $1 ))\ndate -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ\n' }
    local s = text.trim(r.stdout)
    if not s:find("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") then T:refuse("no-clock", s) end
    return s
end
local function tree()
    local t = {}
    for _, f in ipairs(fs.walk(d.rel, {})) do t[#t + 1] = f .. "=" .. fs.read(f) end
    table.sort(t)
    return table.concat(t, "\n")
end
local FUTURE, PAST, NOW = at(31000), at(-31000), at(0)

-- want: the exit code; say: what the output must contain. 0 must write, 2 must write nothing.
local function arm(name, want, say, argv, stdin)
    local a = { PLAN, "--index", d.abs .. "/index.yaml" }
    for _, x in ipairs(argv) do a[#a + 1] = x end
    local before = tree()
    -- 772-4se9/874-idnt: identity is given once, in the canonical shape, so no arm tests it.
    local r = proc.run{ argv = a, cwd = d.abs, stdin = stdin, timeout_ms = 60000, env_unset = { "TILLANDSIAS_*" },
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_AGENT_ID = "linux-fixture-ledger-ts-guard-20260101t000000z" } }
    local o = (r.stdout or "") .. (r.stderr or "")
    local wrote = tree() ~= before
    T:arm(name, r.code == want and wrote == (want == 0) and (not say or text.contains(o, say)), "rc=" .. tostring(r.code) .. " wrote=" .. tostring(wrote) .. " " .. o:sub(1, 400))
end
local CLOCK = "disagrees with this host's clock"
local function event(kind, summary, ...) return { "append-event", "fixture-packet", kind, summary, ... } end
arm("1 a timestamp 8.6 h ahead is refused", 2, CLOCK, event("progress", "invented timestamp", "--ts", FUTURE))
arm("2 a timestamp hours behind is refused", 2, CLOCK, event("progress", "stale timestamp", "--ts", PAST))
arm("3 CONTROL an in-skew timestamp writes", 0, nil, event("progress", "read from the clock", "--ts", NOW))
arm("4 CONTROL omitting --ts writes", 0, nil, event("progress", "no --ts at all"))
arm("5 --backfill reaches backward", 0, nil, event("note", "recording something from this morning", "--ts", PAST, "--backfill"))
arm("6 --backfill never reaches forward", 2, "AHEAD of this host's clock", event("note", "not a backfill", "--ts", FUTURE, "--backfill"))
arm("7 a malformed timestamp is refused", 2, "is not a ledger timestamp", event("note", "bad shape", "--ts", "2026-08-13 22:05:00"))
arm("8 set-field refuses the same drift", 2, CLOCK, { "set-field", "fixture-packet", "priority", "p1", "--reason", "fixture", "--ts", FUTURE })
arm("9 loop-status-append refuses the same drift", 2, CLOCK, { "loop-status-append", "--host", "fixture", "--ts", FUTURE }, "## Cycle drift test\n\n- body\n")
T:finish()
