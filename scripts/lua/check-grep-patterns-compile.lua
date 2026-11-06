-- @trace order:2007-vy3p, order:2006-wahn
-- @env TILLANDSIAS_GREP_SCAN_ROOT
-- @read-env TILLANDSIAS_GREP_SCAN_ROOT
--
-- check-grep-patterns-compile.lua — every literal grep pattern in the shell
-- scripts and hooks compiles under THIS host's grep.
--
-- THE DEFECT THIS EXISTS FOR (2006-wahn, 2026-11-06). pre-push-local-gate.sh's
-- attestation-grammar ERE began '^(|...'. GNU grep accepts the empty
-- alternative; BSD grep (macOS) rejects it with exit 2, and `if grep -qv`
-- read exit 2 as "no bad line", so on macOS the plan-only lane admitted every
-- line. A pattern that only one grep rejects passes every gate on the other
-- host. This decider runs where the gate runs, so a pattern this host's grep
-- cannot compile refuses on the host that would mis-run it.
--
-- WHAT IT READS. Every `grep [flags] '<pattern>'` with a single-quoted
-- pattern in scripts/*.sh and scripts/hooks/*. -F patterns are skipped (they
-- cannot fail to compile). A pattern spliced with '"'"' (the quote is closed
-- and reopened around a literal quote) is skipped too: the text between the
-- quotes is not the pattern grep receives.
--
-- PORTABILITY, ON EVERY HOST. GNU grep accepts an empty alternative in an
-- ERE ('(|a)', 'a||b', '(a|)'); BSD grep rejects it. A Linux gate compiling
-- with GNU grep would never see the 2006-wahn pattern, so an ERE with an empty
-- alternative is refused by its text wherever this runs (bracket expressions
-- and escaped characters are removed first, so '[(|]' and '\(|' are not it).
-- Write the optional form instead: '^(a|b)?$'.
--
-- HOW (inside the 5 s door deadline). All ERE patterns go to one -f file and
-- all BRE patterns to another, and grep compiles each file once against an
-- empty input. Only when a file fails (exit 2) is it bisected, one pattern
-- per run, to name the culprits.
--
-- Verdict grammar, one line on stdout (detail on stderr):
--   ok:grep-patterns-compile:<n> patterns                    exit 0
--   violation:grep-patterns-compile:<file>:<line>[,...]       exit 1
--   could-not-run:grep-patterns-compile:<reason>              exit 3

local ROOT = env.get("TILLANDSIAS_GREP_SCAN_ROOT") or "."
local SCRATCH = "target/plan-scratch/grep-compile-" .. tostring(math.random(100000, 999999))

local function scripts_under(dir, only_sh)
    local ok, walked = pcall(fs.walk, dir)
    local list = {}
    if not ok or type(walked) ~= "table" then return list end
    for _, p in ipairs(walked) do
        local rel = p:sub(#dir + 2)
        if not rel:find("/", 1, true) and (not only_sh or p:find("%.sh$")) then
            list[#list + 1] = p
        end
    end
    table.sort(list)
    return list
end

local files = scripts_under(ROOT .. "/scripts", true)
for _, p in ipairs(scripts_under(ROOT .. "/scripts/hooks", false)) do files[#files + 1] = p end
if #files == 0 then
    verdict.emit("could-not-run:grep-patterns-compile:no scripts under " .. ROOT .. "/scripts", 3)
end

-- { file, line, pattern, ere }
local found = {}
for _, path in ipairs(files) do
    local ok, body = pcall(fs.read, path)
    if ok and body then
        local n = 0
        for line in (body .. "\n"):gmatch("([^\n]*)\n") do
            n = n + 1
            if not line:match("^%s*#") then
                local pos = 1
                while true do
                    local s, e = line:find("grep%s+", pos)
                    if not s then break end
                    local before = s > 1 and line:sub(s - 1, s - 1) or " "
                    pos = e + 1
                    if before:match("[%w_%-%.]") then goto continue end
                    local flags = ""
                    while true do
                        local f = line:match("^(%-%-?[%w%-]+)%s+", pos)
                        if not f or f == "--" then
                            if f == "--" then pos = pos + #line:match("^%-%-%s+", pos) end
                            break
                        end
                        flags = flags .. " " .. f
                        pos = pos + #line:match("^%-%-?[%w%-]+%s+", pos)
                    end
                    if line:sub(pos, pos) == "'" then
                        local close = line:find("'", pos + 1, true)
                        if close then
                            local pat = line:sub(pos + 1, close - 1)
                            local after = line:sub(close + 1, close + 1)
                            local fixed = flags:find("%-[%a]*F") or flags:find("%-%-fixed%-strings")
                            local ere = flags:find("%-[%a]*E") or flags:find("%-%-extended%-regexp")
                            if not fixed and after ~= '"' and pat ~= "" then
                                local rel = path:sub(1, #ROOT + 1) == ROOT .. "/" and path:sub(#ROOT + 2) or path
                                found[#found + 1] = { file = rel, line = n, pattern = pat, ere = ere ~= nil }
                            end
                            pos = close + 1
                        end
                    end
                    ::continue::
                end
            end
        end
    end
end

fs.mkdir(SCRATCH)
fs.write(SCRATCH .. "/empty", "")

local function compiles(patterns, ere)
    local text_ = table.concat(patterns, "\n") .. "\n"
    fs.write(SCRATCH .. "/patterns", text_)
    local argv = { "grep", "-q" }
    if ere then argv[#argv + 1] = "-E" end
    argv[#argv + 1] = "-f"
    argv[#argv + 1] = SCRATCH .. "/patterns"
    argv[#argv + 1] = SCRATCH .. "/empty"
    local r = proc.run({ argv = argv, env = { LC_ALL = "C" }, timeout_ms = 20000 })
    if r.status ~= "exited" then
        verdict.emit("could-not-run:grep-patterns-compile:grep " .. tostring(r.status), 3)
    end
    return r.code ~= 2, r.stderr
end

local bad = {}

-- The empty-alternative refusal, by text (see PORTABILITY above).
-- Reduce an ERE to its operators: an escaped character and a whole bracket
-- expression (with its [:class:], [=e=] and [.c.] items, and a leading ] or ^]
-- that is a literal) each become one atom "x".
local function operators(pat)
    local out, i, n = {}, 1, #pat
    while i <= n do
        local c = pat:sub(i, i)
        if c == "\\" then
            out[#out + 1] = "x"; i = i + 2
        elseif c == "[" then
            local j = i + 1
            if pat:sub(j, j) == "^" then j = j + 1 end
            if pat:sub(j, j) == "]" then j = j + 1 end
            while j <= n and pat:sub(j, j) ~= "]" do
                local two = pat:sub(j, j + 1)
                if two == "[:" or two == "[=" or two == "[." then
                    local close = pat:find(pat:sub(j + 1, j + 1) .. "]", j + 2, true)
                    j = close and close + 2 or n + 1
                else
                    j = j + 1
                end
            end
            out[#out + 1] = "x"; i = j + 1
        else
            out[#out + 1] = c; i = i + 1
        end
    end
    return table.concat(out)
end
local function empty_alternative(pat)
    local p = operators(pat)
    return p:find("(|", 1, true) or p:find("||", 1, true) or p:find("|)", 1, true)
        or p:find("^|") or p:find("|$")
end
local flagged = {}
for _, f in ipairs(found) do
    if f.ere and empty_alternative(f.pattern) then
        flagged[f] = true
        bad[#bad + 1] = f.file .. ":" .. f.line
        log.raw("  " .. f.file .. ":" .. f.line .. " (ERE) has an empty alternative, which BSD grep rejects")
        log.raw("    and GNU grep accepts, so it passes a Linux gate and fails open on macOS: " .. f.pattern:sub(1, 160))
    end
end

for _, ere in ipairs({ true, false }) do
    local group = {}
    for _, f in ipairs(found) do
        if f.ere == ere then group[#group + 1] = f end
    end
    local pats = {}
    for _, f in ipairs(group) do pats[#pats + 1] = f.pattern end
    if #pats > 0 and not compiles(pats, ere) then
        for _, f in ipairs(group) do
            local ok, err = true, nil
            if not flagged[f] then ok, err = compiles({ f.pattern }, ere) end
            if not ok then
                bad[#bad + 1] = f.file .. ":" .. f.line
                log.raw("  " .. f.file .. ":" .. f.line .. (ere and " (ERE)" or " (BRE)") ..
                    " does not compile under this grep: " .. text.trim(err or ""))
                log.raw("    pattern: " .. f.pattern:sub(1, 160))
            end
        end
    end
end

proc.run({ argv = { "rm", "-rf", SCRATCH }, timeout_ms = 10000 })

if #bad > 0 then
    log.raw("  A pattern this grep rejects makes grep exit 2, and `if grep -q` reads exit 2")
    log.raw("  as a clean miss: the check passes without having run (2006-wahn). Rewrite it")
    log.raw("  in a form both GNU and BSD grep accept (for an empty alternative, an optional")
    log.raw("  group: '^(a|b)?$' rather than '^(|a|b)$').")
    verdict.emit("violation:grep-patterns-compile:" .. table.concat(bad, ","), 1)
end
verdict.emit("ok:grep-patterns-compile:" .. #found .. " patterns", 0)
