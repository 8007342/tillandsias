-- @trace order:1753-p925
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-preflight-door-many-guards.lua — 1753-p925's exit criteria.
--
-- THE DEFECT. On darwin, /bin/bash 3.2 ran the preflight door's late worktree
-- sweep (the EXIT trap) as one `< <(git worktree list)` process substitution
-- per guard root. Each is an async child whose SIGCHLD bash reaps with malloc
-- inside the signal handler; at a 260-guard roster one landed inside a
-- realloc every run, and bash aborted on heap corruption with exit 133 AFTER
-- printing `ok:`/`partial:preflight … refused=0`. MEASURED 2026-10-16 with this
-- fixture's own seam: 300 trivial guards, rc=133 and a bash crash report on
-- the code before the fix; rc=0 after it, at 300 and at 500.
--
--   1 MANY    the REAL door (./build.sh --preflight, under /bin/bash, the
--             roster replaced through TILLANDSIAS_PREFLIGHT_ROSTER_FILE) over
--             300 trivial guards exits 0 with ok:preflight … sum=300. On a
--             Linux host /bin/bash is bash 5, so the same arm covers it.
--   2 CAUSE   no `_pf_*` function in build.sh reads a process substitution
--             (`< <(`), so the count is not what this pins: a door that
--             reintroduces one fails here at any roster size.
--
-- Usage: tillandsias-plan script run scripts/lua/test-preflight-door-many-guards.lua

local N = 300
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("preflight-door-many-guards", "git rev-parse --show-toplevel did not answer")
end
local have = proc.run({ argv = { "test", "-x", "/bin/bash" }, timeout_ms = 10000 })
if have.status ~= "exited" or have.code ~= 0 then
    verdict.could_not_run("preflight-door-many-guards", "no /bin/bash on this host")
end

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name .. (got and (" — " .. got) or "")) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

-- 2 CAUSE (static, cheap: first)
local build = fs.read("build.sh")
local offenders = {}
local in_pf, fname = false, nil
for n, line in ipairs(text.lines(build)) do
    local f = line:match("^(_pf_[%w_]+)%(%)%s*{")
    if f then in_pf, fname = true, f
    elseif in_pf and line:match("^}") then in_pf = false
    elseif in_pf and not line:match("^%s*#") and line:find("< <(", 1, true) then
        offenders[#offenders + 1] = fname .. ":" .. n
    end
end
arm("2 CAUSE no _pf_* door function reads a process substitution", #offenders == 0,
    #offenders == 0 and "none" or table.concat(offenders, ", "))

-- 1 MANY
local REL = "target/plan-scratch/door-many-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
local roster = {}
for i = 1, N do
    local p = REL .. "/check-zz-" .. i .. ".sh"
    fs.write(p, "#!/bin/bash\necho ok:zz-" .. i .. "\n")
    roster[#roster + 1] = p
end
fs.write(REL .. "/roster", table.concat(roster, "\n") .. "\n")
local r = proc.run({ argv = { "/bin/bash", "./build.sh", "--preflight" }, cwd = ROOT, timeout_ms = 600000,
    env = { TILLANDSIAS_PREFLIGHT_ROSTER_FILE = ROOT .. "/" .. REL .. "/roster" } })
local outp = (r.stdout or "") .. "\n" .. (r.stderr or "")
local v = outp:match("(ok:preflight:ran=%d+[^\n]*)") or outp:match("((%a+):preflight:ran=[^\n]*)") or "(no verdict)"
arm("1 MANY the real door over " .. N .. " trivial guards exits 0 under /bin/bash",
    r.status == "exited" and r.code == 0 and v:find("^ok:preflight:ran=" .. N .. " ") ~= nil
    and v:find(" sum=" .. N .. " ", 1, true) ~= nil,
    "status=" .. tostring(r.status) .. " rc=" .. tostring(r.code) .. " " .. v:sub(1, 120))
proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })

if #failed > 0 then
    verdict.emit("violation:preflight-door-many-guards:" .. #failed .. "-failed", 1)
end
verdict.ok("preflight-door-many-guards", "2 arms, N=" .. N)
