-- @trace order:915-wkm2, order:1738-wqmt
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-scratchpad-headroom.lua — fixture for scripts/lua/check-scratchpad-headroom.lua.
-- Ported from scripts/test-scratchpad-headroom.sh with the guard (1738-wqmt);
-- same arms. The stubs are named through the guard's seams
-- (TILLANDSIAS_HEADROOM_QUOTA_BIN / _DF_BIN, `absent` = no such tool) rather
-- than prepended to PATH: the shell fixture's first version found the SYSTEM
-- quota because a prepended bin dir cannot hide one.
--
-- THE PROPERTY: report what you can actually USE, and never report a filesystem
-- number as a quota headroom. `df` sees the tmpfs size (systemd default: 50% of
-- RAM); the usrquota can sit far below it, so writes fail while df looks fine.
--   1 ample quota -> ok, with the QUOTA's numbers, not df's
--   2 tight quota -> degraded, with the real headroom, saying df OVERSTATES
--   3 THE 4.6x SPREAD: one absolute threshold classifies both fleet hosts, and
--     the warned host is the EMPTIER one by percentage (a % rule inverts both)
--   4 NEGATIVE CONTROL: quota-exhausted and disk-full are distinct verdicts, the
--     no-quota-tool path names DISK and says it is not a quota headroom
--   5 no quota configured -> skip:no-quota
--   6 ADVISORY, NEVER A GATE: every verdict exits 0
--   7 every verdict matches the pinned grammar
--
-- Usage: tillandsias-plan script run scripts/lua/test-scratchpad-headroom.lua [-- --plan <bin>]

local GUARD_REL = "scripts/lua/check-scratchpad-headroom.lua"
if not fs.exists(GUARD_REL) then
    verdict.emit("refused:scratchpad-headroom-fixture:guard-missing", 1)
end
local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("scratchpad-headroom-fixture", "no plan binary named (--plan, TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 60000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
local REL = "target/plan-scratch/scratch-headroom-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
fs.mkdir(REL)

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end

-- stub(used, limit, df_avail_mb, mode) -> quota bin (or "absent"), df bin.
-- mode: "normal" | "no-quota-tool" | "no-quota-rows".
local n = 0
local function stub(used, limit, dfm, mode)
    n = n + 1
    local q = "absent"
    if mode ~= "no-quota-tool" then
        q = W .. "/quota" .. n
        local body = {
            "#!/usr/bin/env bash",
            'echo "Disk quotas for user test (uid 1000): "',
            'echo "     Filesystem   space   quota   limit   grace   files   quota   limit   grace"',
        }
        if mode ~= "no-quota-rows" then
            body[#body + 1] = "echo '          tmpfs   " .. used .. "   " .. limit .. "   " .. limit .. "           100       0       0'"
        end
        fs.write(REL .. "/quota" .. n, table.concat(body, "\n") .. "\n")
        run({ "chmod", "+x", q })
    end
    local d = W .. "/df" .. n
    fs.write(REL .. "/df" .. n, table.concat({
        "#!/usr/bin/env bash",
        'echo "Filesystem 1M-blocks Used Available Use% Mounted on"',
        'echo "tmpfs 99999 0 ' .. dfm .. ' 1% /tmp"',
    }, "\n") .. "\n")
    run({ "chmod", "+x", d })
    return q, d
end

-- guard(q, d) -> verdict line, stderr, exit code
local function guard(q, d)
    local r = run({ PLAN, "script", "run", ROOT .. "/" .. GUARD_REL }, { env = {
        PATH = "/usr/bin:/bin",
        TILLANDSIAS_SCRATCHPAD_DIR = W,
        TILLANDSIAS_HEADROOM_QUOTA_BIN = q,
        TILLANDSIAS_HEADROOM_DF_BIN = d,
    } })
    local ls = text.lines(r.stdout or "")
    local rc = (r.status == "exited") and r.code or -1
    return text.trim(ls[#ls] or ""), r.stderr or "", rc
end

local codes = {}
local function g(q, d)
    local v, e, rc = guard(q, d)
    codes[#codes + 1] = rc
    return v, e
end

-- 1. Ample quota -> ok, and the numbers are the QUOTA's, not df's.
local v = g(stub("1000M", "25564M", 99999))
check("1 ample quota -> ok with quota-derived numbers", v == "ok:scratchpad-headroom:24564m-of-25564m", "got " .. v)

-- 2. Tight quota -> degraded, AND it must say df overstates. The live lenovinha
--    shape: 3905M usable, df claiming 5286M.
local e
v, e = g(stub("1620M", "5525M", 5286))
check("2 tight quota -> degraded with real headroom (3905m)", v == "degraded:scratchpad-headroom-low:3905m-of-5525m", "got " .. v)
check("2b names df as OVERSTATING what can be used", text.contains(e, "OVERSTATES"), "stderr=[" .. e .. "]")

-- 3. THE 4.6x SPREAD: one absolute threshold, both hosts classified right.
local len = g(stub("1620M", "5525M", 5286))
local mac = g(stub("15900M", "25564M", 20000))
check("3 one absolute threshold classifies BOTH hosts across a 4.6x spread",
    string.find(len, "^degraded:") ~= nil and string.find(mac, "^ok:") ~= nil, "lenovinha=" .. len .. " macuahuitl=" .. mac)
-- Stated the RIGHT way round (the shell fixture's second bug): the warned host
-- is EMPTIER by percentage. Any "warn above N%" rule passes the host that will
-- wedge and warns the one that will not.
local lp, mp = math.floor(1620 * 100 / 5525), math.floor(15900 * 100 / 25564)
check("3b the WARNED host is emptier by percentage (" .. lp .. "% vs " .. mp .. "%)", lp < mp, "the arm no longer shows the trap")

-- 4. NEGATIVE CONTROL: quota-exhausted and disk-full are DIFFERENT verdicts.
local quota_case = g(stub("5400M", "5525M", 99999))
local disk_case, disk_err = g(stub("0", "0", 200, "no-quota-tool"))
check("4 quota-exhausted and disk-full are distinct verdicts",
    string.find(quota_case, "^degraded:") ~= nil and string.find(disk_case, "^degraded:") ~= nil and quota_case ~= disk_case,
    "quota=" .. quota_case .. " disk=" .. disk_case)
check("4b the no-quota-tool path names it DISK, not quota", string.find(disk_case, "^degraded:scratchpad%-disk%-low:") ~= nil, "got " .. disk_case)
check("4c says outright it is filesystem free space, not a quota headroom",
    text.contains(string.lower(disk_err), "not a quota headroom"), "stderr=[" .. disk_err .. "]")

-- 5. No quota configured -> skip, not a false alarm.
local none = g(stub("0", "0", 99999, "no-quota-rows"))
check("5 no quota configured -> skip:no-quota", none == "skip:no-quota", "got " .. none)

-- 6. ADVISORY, NEVER A GATE — every path exits 0.
local nonzero = {}
for i, c in ipairs(codes) do if c ~= 0 then nonzero[#nonzero + 1] = i .. "=" .. c end end
check("6 every verdict exits 0 (advisory, never a gate)", #nonzero == 0, "non-zero: " .. table.concat(nonzero, " "))

-- 7. Grammar: one line, pinned.
local function grammatical(s)
    return string.find(s, "^ok:scratchpad%-headroom:%d+m%-of%-%d+m$") ~= nil
        or string.find(s, "^degraded:scratchpad%-headroom%-low:%d+m%-of%-%d+m$") ~= nil
        or string.find(s, "^degraded:scratchpad%-disk%-low:%d+m$") ~= nil
        or s == "skip:no-quota" or s == "skip:no-scratchpad" or s == "skip:no-quota-tool"
end
local bad = {}
for _, s in ipairs({ len, mac, quota_case, disk_case, none }) do
    if not grammatical(s) then bad[#bad + 1] = s end
end
check("7 every verdict matches the pinned grammar", #bad == 0, "escaped: " .. table.concat(bad, " | "))

run({ "rm", "-rf", W })
if failed > 0 then
    verdict.emit("refused:scratchpad-headroom-fixture:" .. failed .. "-of-" .. (passed + failed), 1)
end
verdict.emit("ok:scratchpad-headroom-fixture:all", 0)
