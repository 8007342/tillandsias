-- @trace order:901-jtvi, order:1637-5765
--
-- check-litmus-grep-escapes.lua — refuse regex escapes GNU grep does not
-- define, inside litmus step commands. Ported from
-- scripts/check-litmus-grep-escapes.sh and its rule
-- scripts/lib/litmus-grep-escapes.awk, the shell-to-lua item the 1637-5765
-- dev-route TLS fix carried; same rule, grammar, exit codes and output.
--
-- ── WHAT HAPPENED, AND WHY A LINT RATHER THAN A LESSON ──────────────────────
--
-- 2026-09-04. Two litmus steps matched a TAB-separated projection with
--   grep -qE '^hardware\t[a-z0-9-]+\tloci=[0-9]+\tcontrol=(yes|no)\t'
-- They failed in the runner and passed every hand-check their author ran. It
-- was never SIGPIPE. GNU grep's ERE does not define `\t`: it warns
-- `stray \ before t` on stderr and matches a literal `t`, so `^hardware\t`
-- means `^hardwaret` and cannot match a real tab. rc=1, no match, step fails.
--
-- THE REASON EVERY HAND-CHECK PASSED: the author's interactive `grep` was a
-- shell FUNCTION (a ugrep compat wrapper, which does interpret \t), while the
-- runner gets /usr/bin/grep, GNU grep 3.12, which does not. Shell functions are
-- not exported, so "I ran the command and it worked" was true and meant
-- nothing. MEASURED ON THREE OF THREE LINUX HOSTS (lenovinha, yoga,
-- macuahuitl); the function's origin was searched for and NOT located on any
-- of them, and is recorded as an unexplained condition rather than explained
-- away. Check your own host in three lines:
--   type grep
--   /usr/bin/grep --version | head -1
--   env -i /bin/bash -c 'command -v grep'
--
-- ── THE ALLOWLIST IS MEASURED, NOT REMEMBERED ───────────────────────────────
--
-- Measured against /usr/bin/grep 3.12 by checking for the `stray \` warning:
--   defined (GNU extensions): \s \S \w \W \b \B \< \>  and \1..\9 backrefs
--   UNDEFINED (warns stray) : \t \d \n \r \0 \p \x \u \e \a
-- The refusal set is the second row, expressed as an allowlist of the first, so
-- a future GNU release adding an escape does not turn this guard into a false
-- positive generator. A guard that fires on working code gets switched off.
--
-- ── WHAT IS DELIBERATELY NOT REFUSED ────────────────────────────────────────
--
-- `$(printf '\t')` is the CORRECT idiom: the backslash is consumed by printf in
-- the shell and grep receives a real tab. Those substitutions are removed
-- before the line is examined. `grep -F` interprets no regex and `grep -P` is
-- PCRE, where these escapes are defined, so both are skipped. SIGPIPE is not
-- this guard's business; 792-ksr8 owns that surface.
--
-- Usage: tillandsias-plan script run scripts/lua/check-litmus-grep-escapes.lua [-- <dir>]
-- <dir> (default openspec/litmus-tests) must be inside the repository.
--
-- GRAMMAR (one line on stdout)
--   ok:litmus-grep-escapes:<n> checked
--   violation:litmus-grep-escapes:<count>

local DIR = arg[1] or "openspec/litmus-tests"
if not fs.exists(DIR) then
    verdict.emit("ok:litmus-grep-escapes:0 checked (no " .. DIR .. ")", 0)
end

local ALLOWED = "sSwWbB<>123456789"

-- "<file>:<line>: <bad escapes>" for each grep PATTERN argument on `line` that
-- carries an escape GNU grep does not define. Only the pattern argument is
-- examined, never the rest of the command, where a later awk or printf owns
-- its own backslashes.
local function line_hits(file, n, line, hits)
    line = line:gsub("%$%([^)]*printf[^)]*%)", "")
    local i = line:find("grep", 1, true)
    while i do
        local rest = line:sub(i + 4)
        line = rest
        local flags = ""
        while true do
            local ws, tok = rest:match("^([ \t]+)(%-[%a%-]+)")
            if not ws then break end
            flags = flags .. tok
            rest = rest:sub(#ws + #tok + 1)
        end
        if not flags:find("[FP]") then
            local pat = rest:match("^[ \t]+'([^']*)'") or rest:match('^[ \t]+\\"([^\\]*)\\"') or ""
            if pat ~= "" then
                pat = pat:gsub("\\\\", "\\") -- YAML spelling -> shell spelling
                local bad = ""
                local k = 1
                while k < #pat do
                    if pat:sub(k, k) == "\\" then
                        local c = pat:sub(k + 1, k + 1)
                        if c:match("^[%a%d]$") and not ALLOWED:find(c, 1, true) then
                            bad = bad .. "\\" .. c .. " "
                        end
                        k = k + 1
                    end
                    k = k + 1
                end
                if bad ~= "" then hits[#hits + 1] = file .. ":" .. n .. ": " .. bad end
            end
        end
        i = line:find("grep", 1, true)
    end
end

local files = fs.walk(DIR, { suffix = ".yaml" })
table.sort(files)
local hits = {}
for _, file in ipairs(files) do
    local ok, body = pcall(fs.read, file)
    if ok and body then
        local n = 0
        for l in body:gmatch("([^\n]*)\n?") do
            n = n + 1
            line_hits(file, n, l, hits)
        end
    end
end

if #hits == 0 then
    verdict.emit("ok:litmus-grep-escapes:" .. #files .. " checked", 0)
end
for _, h in ipairs(hits) do out.line("  " .. h) end
out.line("      GNU grep warns 'stray \\ before <c>' and matches the BARE LETTER, so")
out.line("      '^col\\t' means '^colt' and never matches a tab. Your interactive shell")
out.line("      may resolve a DIFFERENT grep than the runner does — see this script's")
out.line("      header, and check with: type grep; env -i /bin/bash -c 'command -v grep'")
out.line("      Fix: \"$(printf '\\t')\", or awk -F'\\t', or a case pattern.")
verdict.emit("violation:litmus-grep-escapes:" .. #hits, 1)
