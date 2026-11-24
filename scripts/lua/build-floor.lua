-- @env TILLANDSIAS_FLOOR_BASH TILLANDSIAS_FLOOR_ROOT TILLANDSIAS_FLOOR_BASE TILLANDSIAS_FLOOR_BUDGET_S TILLANDSIAS_FLOOR_ORDER PATH HOME
-- @trace order:2130-fl0r
--
-- build-floor.lua: `./build.sh --floor`, the required local check before a
-- work/* push (operator 2026-11-20: it REPLACES the worker-side --preflight
-- requirement; the landing queue runs the full preflight and gate on arrival).
-- Under two minutes, no build, on a memory-limited host:
--   1 fmt    a changed .rs makes `cargo fmt --all -- --check` run (no compile)
--   2 lua    every changed .lua parses (load(), never run)
--   3 litmus the litmus tests the branch's packet names (litmus:<name> in its
--            row) plus every litmus file the diff touches, run one by one
--            through scripts/run-litmus-test.sh --test. A size:long test, or
--            one that would overrun the budget, is SKIPPED BY NAME, never
--            silently; the queue runs it.
-- The diff is against the merge base with origin/linux-next (TILLANDSIAS_FLOOR_BASE
-- overrides), working tree included. The packet comes from the branch name
-- work/<order> (TILLANDSIAS_FLOOR_ORDER overrides).
-- Verdict: ok:floor:fmt=<s>:lua=<n>:litmus=<ran>ran/<skipped>skipped:<secs>s (0)
--        | violation:floor:<what> (1) | could-not-run:floor:<why> (2)
local t0 = time.now_ms()
local budget_ms = (tonumber(env.get("TILLANDSIAS_FLOOR_BUDGET_S") or "") or 110) * 1000
local function run(argv, ms) return proc.run{ argv = argv, timeout_ms = ms or 60000 } end
local function out(r) return text.trim(r.stdout or "") end
local ROOT = env.get("TILLANDSIAS_FLOOR_ROOT")
if ROOT == nil or ROOT == "" then ROOT = "." end
local function at(p) return ROOT .. "/" .. p end
local function git(args) local a = { "git", "-C", ROOT }; for _, x in ipairs(args) do a[#a + 1] = x end; return a end
-- A native Windows process resolves a bare `bash` to WSL's bash.exe, not the
-- caller's Git Bash; build.sh passes its own as TILLANDSIAS_FLOOR_BASH.
local BASH = env.get("TILLANDSIAS_FLOOR_BASH")
if BASH == nil or BASH == "" then BASH = "bash" end
local function left() return budget_ms - (time.now_ms() - t0) end

local base = env.get("TILLANDSIAS_FLOOR_BASE")
if base == nil or base == "" then
    local mb = run(git({ "merge-base", "HEAD", "origin/linux-next" }), 15000)
    if not mb.ok then verdict.emit("could-not-run:floor:no-merge-base-with-origin/linux-next", 2) end
    base = out(mb)
end
local changed = {}
local seen = {}
for _, argv in ipairs({ git({ "diff", "--name-only", "--diff-filter=d", base }),
                        git({ "ls-files", "--others", "--exclude-standard" }) }) do
    for _, l in ipairs(text.lines(out(run(argv, 30000)))) do
        if l ~= "" and not seen[l] then seen[l] = true; changed[#changed + 1] = l end
    end
end
log.raw("floor: " .. #changed .. " changed path(s) since " .. base:sub(1, 12))

local problems = {}

-- 1 fmt
local fmt = "none"
for _, p in ipairs(changed) do
    if p:find("%.rs$") then fmt = "pending"; break end
end
if fmt == "pending" then
    local r = run({ "cargo", "fmt", "--all", "--manifest-path", at("Cargo.toml"), "--", "--check" }, 90000)
    if r.ok then fmt = "clean"
    elseif r.code == nil or (r.stderr or ""):find("not found", 1, true) or (r.stderr or ""):find("no such", 1, true) then
        verdict.emit("could-not-run:floor:cargo-fmt-unavailable", 2)
    else
        local files = {}
        -- rustfmt names a file as `Diff in <path>:<line>:` (older) or
        -- `Diff in <path> at line <n>:` (newer); read both, as check-rust-lints does.
        for _, l in ipairs(text.lines(r.stdout or "")) do
            local p = l:match("^Diff in (.-):%d+:%s*$") or l:match("^Diff in (.-) at line %d+:%s*$")
            if p then files[p] = true end
        end
        local names = {}
        for f in pairs(files) do names[#names + 1] = f end
        table.sort(names)
        log.raw(r.stdout or "")
        problems[#problems + 1] = "fmt:" .. (#names > 0 and table.concat(names, ",") or "cargo-fmt-check-failed")
        fmt = "dirty"
    end
end
log.raw("floor: fmt=" .. fmt)

-- 2 lua parse
local lua_n = 0
for _, p in ipairs(changed) do
    if p:find("%.lua$") and fs.exists(at(p)) then
        lua_n = lua_n + 1
        local f, err = load(fs.read(at(p)) or "", "@" .. p)
        if not f then problems[#problems + 1] = "lua-parse:" .. tostring(err) end
    end
end
log.raw("floor: lua=" .. lua_n .. " parsed")

-- 3 litmus: the packet's own, plus the litmus files the diff touches.
local order = env.get("TILLANDSIAS_FLOOR_ORDER")
if order == nil or order == "" then
    local br = out(run(git({ "symbolic-ref", "--short", "HEAD" }), 5000))
    order = br:match("^work/(%d+%-%w+)") or ""
end
local names, named = {}, {}
local function want(n) if n ~= "" and not named[n] then named[n] = true; names[#names + 1] = n end end
if order ~= "" and fs.exists(at("plan/index.d")) then
    local hits = run(git({ "grep", "-l", "order: " .. order, "--", "plan/index.d" }), 30000)
    for _, f in ipairs(text.lines(out(hits))) do
        for n in (fs.read(at(f)) or ""):gmatch("litmus:([%w%-_]+)") do want(n) end
    end
end
for _, p in ipairs(changed) do
    local n = p:match("^openspec/litmus%-tests/litmus%-(.+)%.yaml$")
    if n and fs.exists(at(p)) then want(n) end
end
local ran, skipped, skipped_names = 0, 0, {}
for _, n in ipairs(names) do
    local file = "openspec/litmus-tests/litmus-" .. n .. ".yaml"
    local y = fs.exists(at(file)) and fs.read(at(file)) or ""
    local size = y:match("\nsize:%s*(%w+)") or "?"
    if y == "" then
        problems[#problems + 1] = "litmus-missing:" .. n
    elseif size == "long" or left() < 20000 then
        skipped = skipped + 1
        skipped_names[#skipped_names + 1] = n .. "(" .. (size == "long" and "size:long" or "budget") .. ")"
    else
        local r = run({ BASH, at("scripts/run-litmus-test.sh"), "--test", "litmus:" .. n, "--compact" }, math.max(left(), 20000))
        ran = ran + 1
        if not r.ok then
            log.raw(text.trim((r.stdout or "") .. "\n" .. (r.stderr or "")))
            problems[#problems + 1] = "litmus:" .. n
        end
    end
end
if #skipped_names > 0 then log.raw("floor: skipped (the queue runs them): " .. table.concat(skipped_names, ", ")) end
log.raw("floor: litmus " .. ran .. " ran, " .. skipped .. " skipped" .. (order ~= "" and (" (packet " .. order .. ")") or " (no work/<order> branch)"))

local secs = math.floor((time.now_ms() - t0) / 1000)
if #problems > 0 then verdict.emit("violation:floor:" .. table.concat(problems, ";"), 1) end
verdict.emit(string.format("ok:floor:fmt=%s:lua=%d:litmus=%dran/%dskipped:%ds", fmt, lua_n, ran, skipped, secs), 0)
