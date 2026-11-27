-- @trace order:2249-tif9, order:2256-mvmy
--
-- cost-intake-on-landings.lua — what the bundle intake gate would SELECT for
-- every landing in a window, so its run time can be priced over real changes
-- rather than a handful of measured ones. Selection only: each landing's tree
-- is checked out detached and `gate-changed.sh --list --intake` runs there;
-- no fixture, no cargo, nothing executes.
--
-- Usage:
--   tillandsias-plan script run scripts/lua/cost-intake-on-landings.lua -- <since> <selector> [<limit>]
--     <since>     git --since value for first-parent merges of origin/linux-next
--     <selector>  the gate-changed.sh to judge with (a path; usually the newest)
--
-- One line per landing:
--   land <merge> <pr> kind=<pr|plan-adopt> files=<n> verdict=<heavy|intake|plan-lane|error>
--        serial=<n> pool=<n> deferred=<n> crates=<n> headless=<0|1> heavy=<reason>
-- serial: selected fixtures --check runs one at a time (an inline build.sh
-- block, or a .step declaring STEP_SERIAL); pool: the rest. The pricing is
-- done from these counts by a separate step, calibrated on measured runs.
--
-- Verdict: ok:cost-intake-on-landings:<n> landings

local fixture = require "common.fixture"
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local since, selector, limit = arg and arg[1], arg and arg[2], tonumber(arg and arg[3] or "") or 100000
if not since or not selector then
    verdict.could_not_run("cost-intake-on-landings", "usage: -- <since> <selector-path> [<limit>]")
end

local function git(args, cwd)
    local argv = { "git" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return proc.run{ argv = argv, cwd = cwd or ROOT, timeout_ms = 300000 }
end

local log = git{ "log", "--first-parent", "origin/linux-next", "--merges", "--since=" .. since, "--format=%h %s" }
local lands = {}
for _, l in ipairs(text.lines(log.stdout or "")) do
    local h, rest = l:match("^(%S+) (.*)$")
    if h and rest:find("land%(") then
        lands[#lands + 1] = { h = h, pr = rest:match("land%((%d+)%)") or "?",
            kind = rest:find("adopted over a plan%-only", 1) and "plan-adopt" or "pr" }
    end
end

local T = fixture.new("cost-intake-on-landings")
local S = T:scratch("cost")
local wt = S.abs .. "/wt"
local n = 0
for i, L in ipairs(lands) do
    if i > limit then break end
    n = n + 1
    local files = git{ "diff", "--name-only", L.h .. "^1", L.h }
    local nf = #text.lines(text.trim(files.stdout or ""))
    fs.write(S.rel .. "/changed", files.stdout or "")
    local add = git{ "worktree", "add", "-q", "--detach", wt, L.h }
    local verdict_s, ser, pool, def, crates, headless, heavy = "error", 0, 0, 0, 0, 0, ""
    if add.code == 0 then
        local r = proc.run{ argv = { SH, selector, "--list", "--intake", "--files", S.abs .. "/changed" }, cwd = wt,
            timeout_ms = 300000, env = { TILLANDSIAS_GATE_CHANGED_ROOT = wt, GATE_CHANGED_KEEP = "1" } }
        local o = r.stdout or ""
        local W = (r.stderr or ""):match("work=(%S+)")
        -- the population: path -> its .step file ("" for an inline build.sh block)
        local stepof = {}
        if W then
            local pop = proc.run{ argv = { "cat", W .. "/pop" } }.stdout or ""
            for _, row in ipairs(text.lines(pop)) do
                local f = {}
                for c in (row .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = c end
                if f[3] then stepof[f[3]] = f[7] or "" end
            end
        end
        local serial_step = {}
        for _, l in ipairs(text.lines(o)) do
            if text.starts_with(l, "heavy:") then verdict_s = "heavy"; heavy = l:match("^heavy:(%S+)") or ""
            elseif text.starts_with(l, "route:plan-lane") then verdict_s = "plan-lane"
            elseif text.starts_with(l, "select:intake") then
                verdict_s = "intake"
                def = tonumber(l:match("deferred=(%d+)")) or 0
                crates = tonumber(l:match("crates=(%d+)/")) or 0
            elseif text.starts_with(l, "select:crate:tillandsias-headless") then headless = 1
            elseif text.starts_with(l, "select:fixture:") then
                local p = l:match("^select:fixture:(%S+)")
                local sf = stepof[p]
                local is_serial = (sf == nil or sf == "")
                if not is_serial then
                    if serial_step[sf] == nil then
                        local body = proc.run{ argv = { "cat", wt .. "/" .. sf } }.stdout or ""
                        serial_step[sf] = body:find("\nSTEP_SERIAL=", 1, true) ~= nil or text.starts_with(body, "STEP_SERIAL=")
                    end
                    is_serial = serial_step[sf]
                end
                if is_serial then ser = ser + 1 else pool = pool + 1 end
            end
        end
        if W then proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end
    end
    out.line(string.format("land %s %s kind=%s files=%d verdict=%s serial=%d pool=%d deferred=%d crates=%d headless=%d heavy=%s",
        L.h, L.pr, L.kind, nf, verdict_s, ser, pool, def, crates, headless, heavy))
    git{ "worktree", "remove", "--force", wt }
end
git{ "worktree", "prune" }
T:cleanup()
verdict.ok("cost-intake-on-landings:" .. n .. " landings")
