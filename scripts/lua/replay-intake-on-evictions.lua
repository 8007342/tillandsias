-- @trace order:2249-tif9, order:2248-zcqh
--
-- replay-intake-on-evictions.lua — ask, for every head the full gate EVICTED,
-- what the bundle intake gate (`gate-changed.sh --intake`, 2248-zcqh) would
-- have said about it. Intake is only safe if what it defers or passes is
-- rarely what evicts: a member that passes intake and then reds the bundle
-- gate costs the whole bundle a bisection. This is the measurement phase 2 is
-- decided on (operator-approved bundle-landing design, 2026-11-22).
--
-- Usage:
--   tillandsias-plan script run scripts/lua/replay-intake-on-evictions.lua -- <heads-file>
--
-- <heads-file>: one eviction per line, `;` or newline separated:
--   <pr> <base> <head> <reason> rc=<n> [step=<evicting fixture path>] [class=<code|flake|host|killed>]
-- `step=` names what the full gate refused on; without it the head is
-- recorded but not scored. `class=` overrides the default class: rc=143/137
-- is `killed` (a killed gate, not code), everything else `code`. Only `code`
-- rows with a step count toward recall.
--
-- For each row: the PR's own change (`git diff --name-only base...head`), a
-- detached worktree at the head (its OWN map: fixtures and inputs as they were
-- then), and gate-changed.sh from THIS tree run there with --list --intake
-- --files. Selection only: nothing is executed in the head's tree.
--
-- Output (stdout), one line per row, then the summary:
--   row <pr> <head> class=<c> verdict=<heavy|intake|error> run=<n> deferred=<d> crates=<k> ms=<t> judged=<caught|caught-heavy|deferred|missed|unscored>
--   summary rows=<n> heavy=<h> scored=<s> caught=<c> deferred=<d> missed=<m> recall=<c/s> median_select_ms=<t>
--
-- Verdict: ok:replay-intake:<n> rows | could-not-run:replay-intake:<why>

local fixture = require "common.fixture"
local ROOT = fixture.repo_root()
local GC = ROOT .. "/scripts/gate-changed.sh"
local SH = "bash"
do
    local ep = text.trim(proc.run{ argv = { "git", "--exec-path" }, timeout_ms = 10000 }.stdout or "")
    if ep:find("^%a:/.*/libexec/git%-core$") then SH = (ep:gsub("/[^/]+/libexec/git%-core$", "/bin/bash.exe")) end
end

local heads = arg and arg[1]
if not heads or heads == "" or not fs.exists(heads) then
    verdict.could_not_run("replay-intake", "usage: replay-intake-on-evictions.lua -- <heads-file>")
end

local function git(args, cwd)
    local argv = { "git" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return proc.run{ argv = argv, cwd = cwd or ROOT, timeout_ms = 300000 }
end

local rows = {}
for rec in (fs.read(heads) .. ";"):gmatch("([^;\n]+)[;\n]") do
    rec = text.trim(rec)
    if rec ~= "" then
        local w = {}
        for t in rec:gmatch("%S+") do w[#w + 1] = t end
        local r = { pr = w[1], base = w[2], head = w[3], reason = w[4] }
        for i = 5, #w do
            local k, v = w[i]:match("^(%w+)=(.*)$")
            if k then r[k] = v end
        end
        r.class = r.class or ((r.rc == "143" or r.rc == "137") and "killed" or "code")
        rows[#rows + 1] = r
    end
end
if #rows == 0 then verdict.could_not_run("replay-intake", "no rows in " .. heads) end

local T = fixture.new("replay-intake")
local S = T:scratch("replay")
local times, n_heavy, scored, caught, deferred, missed = {}, 0, 0, 0, 0, 0

for i, r in ipairs(rows) do
    local line = "row " .. r.pr .. " " .. r.head .. " class=" .. r.class
    local judged = "unscored"
    local d = git{ "diff", "--name-only", r.base .. "..." .. r.head }
    local wt = S.abs .. "/wt-" .. i
    local add = git{ "worktree", "add", "-q", "--detach", wt, r.head }
    if d.code ~= 0 or add.code ~= 0 then
        out.line(line .. " verdict=error run=0 deferred=0 crates=0 ms=0 judged=unscored why="
            .. text.trim((d.stderr or "") .. (add.stderr or "")):gsub("%s+", " "):sub(1, 120))
    else
        fs.write(S.rel .. "/changed-" .. i, d.stdout or "")
        local t0 = time.now_ms()
        local g = proc.run{ argv = { SH, GC, "--list", "--intake", "--files", S.abs .. "/changed-" .. i },
            cwd = wt, timeout_ms = 600000, env = { TILLANDSIAS_GATE_CHANGED_ROOT = wt } }
        local ms = time.now_ms() - t0
        times[#times + 1] = ms
        local o = g.stdout or ""
        local verdict_s, run_n, def_n, crates = "error", 0, 0, 0
        local sel, def_line = {}, ""
        for _, l in ipairs(text.lines(o)) do
            if text.starts_with(l, "heavy:") then verdict_s = "heavy"
            elseif text.starts_with(l, "select:intake") then
                verdict_s = "intake"
                run_n = tonumber(l:match("fixtures=(%d+)/")) or 0
                def_n = tonumber(l:match("deferred=(%d+)")) or 0
                crates = tonumber(l:match("crates=(%d+)/")) or 0
            elseif text.starts_with(l, "select:fixture:") then
                sel[(l:match("^select:fixture:(%S+)") or "")] = true
            elseif text.starts_with(l, "deferred:") then def_line = l end
        end
        if verdict_s == "heavy" then n_heavy = n_heavy + 1 end
        if r.class == "code" and r.step and r.step ~= "" then
            scored = scored + 1
            if verdict_s == "heavy" then judged = "caught-heavy"; caught = caught + 1
            elseif sel[r.step] then judged = "caught"; caught = caught + 1
            elseif def_line:find(r.step, 1, true) then judged = "deferred"; deferred = deferred + 1
            else judged = "missed"; missed = missed + 1 end
        end
        out.line(line .. " verdict=" .. verdict_s .. " run=" .. run_n .. " deferred=" .. def_n
            .. " crates=" .. crates .. " ms=" .. ms .. " judged=" .. judged)
    end
    git{ "worktree", "remove", "--force", wt }
end
git{ "worktree", "prune" }
T:cleanup()

table.sort(times)
local med = #times > 0 and times[math.floor((#times + 1) / 2)] or 0
out.line("summary rows=" .. #rows .. " heavy=" .. n_heavy .. " scored=" .. scored .. " caught=" .. caught
    .. " deferred=" .. deferred .. " missed=" .. missed
    .. " recall=" .. (scored > 0 and (caught .. "/" .. scored) or "n/a") .. " median_select_ms=" .. med)
verdict.ok("replay-intake:" .. #rows .. " rows")
