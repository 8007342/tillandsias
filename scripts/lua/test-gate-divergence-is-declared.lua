-- @trace order:1087-h2z9, order:2341-324y, spec:ci-release
--
-- test-gate-divergence-is-declared.lua — every difference between the landing gate
-- (./build.sh --check) and the release gate (--ci-full, scripts/local-ci.sh) is
-- DECLARED in scripts/gate-divergence-declared.txt. On 2026-09-06 --ci-full was red
-- on nine counts while --check was green on all nine, and no list of the difference
-- existed. Ported from the .sh (2341-324y).
--
--   * a script local-ci invokes and --check does not MUST be declared
--   * a declaration for something no longer in the gap reds too, so the file cannot
--     rot into things that used to be true
--   * the `untriaged` count RATCHETS BOTH WAYS. Above the baseline somebody parked a
--     new difference. Below it the baseline is STALE and leaves room to park one:
--     lowering it belongs in the commit that did the triage (macuahuitl's ruling:
--     a date is a commitment somebody has to remember; a side effect is not). The
--     gate never writes the number itself.
-- A ratchet, not a hard red: there were 22 untriaged on day one, and a gate that reds
-- trunk on day one gets switched off. This does NOT propose litmus in --check
-- (748-tkjx): those rows are classed `excluded`, with that reason.
--
-- Verdicts (one line on stdout):
--   ok:gate-divergence-declared:<gap> | violation:gate-divergence-undeclared:<n> | violation:gate-divergence-ratchet:<n>

local DECL = "scripts/gate-divergence-declared.txt"
local BASELINE_UNTRIAGED = 0 -- 2026-09-12 (1087-h2z9: all 22 triaged). May fall, never rise.

local function note(s) io.stderr:write("  " .. s .. "\n") end
local function lines(s) return ((s:sub(-1) == "\n" or s == "") and s or s .. "\n"):gmatch("([^\n]*)\n") end
local function stop(v, ...) for _, s in ipairs({ ... }) do note(s) end; verdict.emit(v, 1) end

if not fs.exists(DECL) then stop("violation:gate-divergence-undeclared:0", DECL .. " is missing — the declaration IS the mechanism") end
if not (fs.exists("build.sh") and fs.exists("scripts/local-ci.sh")) then
    stop("violation:gate-divergence-undeclared:0", "build.sh or scripts/local-ci.sh missing")
end

-- Every scripts/….sh or .lua path on a line: the longest run of path characters that
-- ends in an extension.
local function paths(line, into)
    local at = 1
    while true do
        local s, e = line:find("scripts/[%w_./%-]+", at)
        if not s then return end
        local run = line:sub(s, e)
        local sh, lua = run:match("^(scripts/.+%.sh)"), run:match("^(scripts/.+%.lua)")
        local hit = sh and lua and (#sh > #lua and sh or lua) or sh or lua
        if hit then into[hit] = true end
        at = hit and s + #hit or s + 1
    end
end
-- Comments go BEFORE scanning: both gates discuss other scripts in prose, and a
-- mention is not an invocation (1055-6yp8).
local function scan(body, comment, into)
    for l in lines(body) do paths((l:gsub(comment, "")), into) end
end

-- 2231-zmzd: local-ci.sh runs every row of its landed-guards roster, so the roster's
-- paths are local-ci's invocations too. 1384-ddua: a decider may be .lua.
local ci, check = {}, {}
scan(fs.read("scripts/local-ci.sh"), "%s*#.*", ci)
local ROSTER = "scripts/lua/local-ci-landed-guards.lua"
if fs.exists(ROSTER) then scan(fs.read(ROSTER), "^%s*%-%-.*", ci) end

local build = "\n" .. fs.read("build.sh")
local from = build:find('\nif [[ "$FLAG_CHECK" == true ]]', 1, true)
if from then scan(build:sub(from + 1), "%s*#.*", check) end
-- The steps are data; STEP_SCRIPT and STEP_LUA are literal by contract (1072-b7eq).
for _, f in ipairs(fs.walk("scripts/gate-steps.d")) do
    local last = {}
    for l in lines(f:match("%.step$") and fs.read(f) or "") do
        local k, v = l:match('^%s*(STEP_%u+)="?([^"]*)"?')
        if k == "STEP_SCRIPT" or k == "STEP_LUA" then last[k] = text.trim(v) end
    end
    for _, v in pairs(last) do if v ~= "" then check[v] = true end end
end

local declared, untriaged = {}, 0
for l in lines(fs.read(DECL)) do
    if not l:find("^%s*#") then
        local p, class = l:match("^%s*(%S+)%s*(%S*)")
        if p then
            declared[p] = true
            if class == "untriaged" then untriaged = untriaged + 1 end
        end
    end
end
local function sorted(t) local k = {}; for p in pairs(t) do k[#k + 1] = p end; table.sort(k); return k end

local gap, ngap, detail = {}, 0, {}
for _, p in ipairs(sorted(ci)) do
    if not check[p] then
        gap[p] = true; ngap = ngap + 1
        if not declared[p] then detail[#detail + 1] = p .. " runs in --ci-full and not in --check, and is not declared in " .. DECL end
    end
end
for _, p in ipairs(sorted(declared)) do
    if not gap[p] then detail[#detail + 1] = p .. " is declared in " .. DECL .. " but is NOT in the gap — wired into --check, or gone; remove the line" end
end
if #detail > 0 then
    for _, s in ipairs(detail) do note(s) end
    stop("violation:gate-divergence-undeclared:" .. #detail,
        "The landing gate and the release gate must not differ by anything nobody wrote down.",
        "Wire it into --check, or add a line to " .. DECL .. " saying why it stays out.")
end
if untriaged > BASELINE_UNTRIAGED then
    stop("violation:gate-divergence-ratchet:" .. untriaged,
        "untriaged is " .. untriaged .. ", baseline " .. BASELINE_UNTRIAGED .. " — the ratchet only turns one way.",
        "A new difference must be wired into --check or given a reason, not parked as untriaged.")
end
if untriaged < BASELINE_UNTRIAGED then
    stop("violation:gate-divergence-ratchet:" .. untriaged,
        "untriaged is " .. untriaged .. " and the baseline still says " .. BASELINE_UNTRIAGED .. " — the baseline is STALE.",
        "Lower BASELINE_UNTRIAGED to " .. untriaged .. " in scripts/lua/test-gate-divergence-is-declared.lua, in this same commit.",
        "Left there, " .. (BASELINE_UNTRIAGED - untriaged) .. " new difference(s) could be parked as untriaged without redding anything.")
end
if untriaged > 0 then
    io.stderr:write("note:gate-divergence-untriaged:" .. untriaged .. " (baseline " .. BASELINE_UNTRIAGED .. ") — checks no landing host runs and nobody decided to exclude\n")
end
verdict.emit("ok:gate-divergence-declared:" .. ngap, 0)
