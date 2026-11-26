-- @trace order:1194-davi, order:2118-9mk4
-- @env TILLANDSIAS_UNRUNNABLE_BASE TILLANDSIAS_GATE_DIFF_BASE
--
-- check-unrunnable-platform-arms.lua — PORTED from
-- check-unrunnable-platform-arms.sh (2118-9mk4, check-[n-z] batch 2).
-- ADVISORY: which changed paths are exercised ONLY by a prover row scoped to
-- other platforms, so this host's ./build.sh --check never runs them.
--
-- Prover rows come from the heredoc <<SPEC ... SPEC in the spec source
-- (default scripts/check-host-tools.sh), one row per line in the documented
-- 8-field shape <tool>|<kind>|<scope>|<platforms>|<prover>|<expect>|<why>|<remedy>.
-- A changed path matches a row whose platforms exclude this host when it IS
-- the prover or ends in /<prover>.
--
-- Grammar (first line on stdout), unchanged from the .sh; EVERY path exits 0:
--   ok:unrunnable-platform-arms:0 of <n> changed paths
--   advisory:unrunnable-platform-arms:<hits> of <n> changed paths   (notice on stderr)
--   skipped:unrunnable-platform-arms:no-spec-source|no-rows|no-diff-base
--   fail:unrunnable-platform-arms:unknown-platform|unparsable-spec
-- The emitted house verdict follows it (ok:, skip: or degraded:), also exit 0.
--
-- Usage: tillandsias-plan script run scripts/lua/check-unrunnable-platform-arms.lua
--          [-- --platform P] [--base REF] [--spec-source FILE]

local SPEC_SOURCE = "scripts/check-host-tools.sh"
local PLATFORM = ""
local function envor(k) local v = env.get(k); if v and v ~= "" then return v end end
local BASE_REF = envor("TILLANDSIAS_UNRUNNABLE_BASE") or envor("TILLANDSIAS_GATE_DIFF_BASE") or "origin/linux-next"

local i = 1
while arg and arg[i] do
    local a = arg[i]
    if a == "--platform" then PLATFORM = arg[i + 1] or ""; i = i + 2
    elseif a == "--base" then BASE_REF = arg[i + 1] or ""; i = i + 2
    elseif a == "--spec-source" then SPEC_SOURCE = arg[i + 1] or ""; i = i + 2
    else i = i + 1 end
end

local function say(line, tok) out.line(line); verdict.emit(tok, 0) end

if PLATFORM == "" then
    local u = proc.run({ argv = { "uname", "-s" }, timeout_ms = 5000 })
    local s = text.trim(u.stdout or "")
    if s == "Darwin" then PLATFORM = "macos"
    elseif s == "Linux" then PLATFORM = "linux"
    elseif s:match("^MINGW") or s:match("^MSYS") or s:match("^CYGWIN") then PLATFORM = "windows"
    else
        log.raw("  uname -s did not resolve to macos/linux/windows; the inventory cannot be scoped")
        say("fail:unrunnable-platform-arms:unknown-platform", "degraded:unrunnable-platform-arms:unknown-platform")
    end
end

if not fs.exists(SPEC_SOURCE) then
    log.raw("  note: " .. SPEC_SOURCE .. " absent — the prover-row inventory has no source, so nothing was examined")
    say("skipped:unrunnable-platform-arms:no-spec-source", "skip:unrunnable-platform-arms:no-spec-source")
end

-- awk: /<<.?SPEC.?$/ opens, /^SPEC$/ closes; inside, rows with a | that are
-- not comments.
local rows, inh = {}, false
for line in ((fs.read(SPEC_SOURCE) or "") .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("<<.?SPEC.?$") then
        inh = true
    else
        if line == "SPEC" then inh = false end
        if inh and line:find("|", 1, true) and not line:match("^%s*#") then rows[#rows + 1] = line end
    end
end
if #rows == 0 then
    log.raw("  note: no prover rows parsed from " .. SPEC_SOURCE .. " — nothing was examined")
    say("skipped:unrunnable-platform-arms:no-rows", "skip:unrunnable-platform-arms:no-rows")
end

local function split(line)
    local f = {}
    for field in (line .. "|"):gmatch("([^|]*)|") do f[#f + 1] = field end
    return f
end
local malformed = 0
for _, r in ipairs(rows) do if #split(r) < 8 then malformed = malformed + 1 end end
if malformed > 0 then
    log.raw("  " .. malformed .. " row(s) in " .. SPEC_SOURCE .. " carry fewer than 8 pipe-separated fields.")
    log.raw("  The documented contract is <tool>|<kind>|<scope>|<platforms>|<prover>|<expect>|<why>|<remedy>.")
    log.raw("  Refusing to guess which column is which: a guard reading the wrong field")
    log.raw("  asserts confidently about a subject nobody named.")
    say("fail:unrunnable-platform-arms:unparsable-spec", "degraded:unrunnable-platform-arms:unparsable-spec")
end

local function git(args)
    local argv = { "git" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return proc.run({ argv = argv, timeout_ms = 60000 })
end
local v = git({ "rev-parse", "--verify", "--quiet", BASE_REF .. "^{commit}" })
if not (v.status == "exited" and v.code == 0) then
    log.raw("  note: base ref '" .. BASE_REF .. "' unavailable — set TILLANDSIAS_UNRUNNABLE_BASE to scope the pass")
    say("skipped:unrunnable-platform-arms:no-diff-base", "skip:unrunnable-platform-arms:no-diff-base")
end

local set, changed = {}, {}
for _, args in ipairs({ { "diff", "--name-only", BASE_REF }, { "diff", "--name-only", "--cached" },
    { "ls-files", "--others", "--exclude-standard" } }) do
    local r = git(args)
    for p in ((r.stdout or "") .. "\n"):gmatch("([^\n]*)\n") do
        if p ~= "" and not set[p] then set[p] = true; changed[#changed + 1] = p end
    end
end
table.sort(changed)

local hits, notice = 0, {}
for _, r in ipairs(rows) do
    local f = split(r)
    local tool, platforms, prover = f[1] or "", f[4] or "", f[5] or ""
    if tool ~= "" and not ("," .. platforms .. ","):find("," .. PLATFORM .. ",", 1, true) and prover ~= "" and prover ~= "-" then
        for _, p in ipairs(changed) do
            if p == prover or p:sub(-(#prover + 1)) == "/" .. prover then
                hits = hits + 1
                notice[#notice + 1] = "  " .. p
                notice[#notice + 1] = "      exercised by the '" .. tool .. "' prover row, which is scoped to: " .. platforms
                notice[#notice + 1] = "      THIS HOST IS '" .. PLATFORM .. "', so ./build.sh --check here NEVER RUNS that arm."
                notice[#notice + 1] = "      A break in it lands green from this host and stays green until a '" .. platforms .. "' host gates."
            end
        end
    end
end

if hits == 0 then
    say("ok:unrunnable-platform-arms:0 of " .. #changed .. " changed paths", "ok:unrunnable-platform-arms")
end
out.line("advisory:unrunnable-platform-arms:" .. hits .. " of " .. #changed .. " changed paths")
for _, l in ipairs(notice) do log.raw(l) end
log.raw("  This is ADVISORY and does not refuse the push (1194-davi). Refusing a " .. PLATFORM .. " land")
log.raw("  over an arm this host cannot run would trade a visibility gap for a worse one.")
log.raw("  Hand the change to a host on that platform, or say on the row why you did not.")
verdict.emit("degraded:unrunnable-platform-arms:" .. hits .. "-advisory", 0)
