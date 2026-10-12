-- @trace order:1570-g4rx, order:1130-i6xj, spec:ci-release
-- @env TILLANDSIAS_PORTABILITY_ROOT
-- @read-env TILLANDSIAS_PORTABILITY_ROOT
--
-- check-portability-idioms.lua — ADVISORY, COUNTED, NEVER BLOCKING. PORTED
-- from check-portability-idioms.sh (1570-g4rx); every rule below is that
-- script's, with the reason each one exists.
--
-- Name shell idioms that pass on the host that wrote them and fail somewhere
-- else. On 2026-09-12 seven of these landed across three hosts in one night,
-- every one green on trunk before it bit, each costing a fleet-wide stall:
--   grep -Rl over a symlink farm   GNU descends symlinked dirs, BSD does not
--                                  (1087-h2z9: five guards reported ORPHAN)
--   rg with no path operand        reads STDIN under a pipe: the gate HUNG
--   sed -i SCRIPT FILE             GNU-only; BSD eats the next arg as a backup
--                                  suffix and silently does nothing (1127-waxf)
--   find -printf                   GNU-only; BSD yields an EMPTY set, silently
--   touch -d                       GNU-only (1129-4su6)
--   literal "current" timestamp    a fixture with an EXPIRY DATE
--   ugrep/rg installed AS grep     NOT DETECTABLE HERE, see LIMITS
-- plus four more found since: string-compared wc counts (BSD pads), readlink
-- -f, date -d, stat -c.
--
-- WHY ADVISORY AND NOT A GATE. Four of those seven froze a platform; a check
-- able to do the same thing to fix them would cost more than it saves. The
-- counted number is the signal.
--
-- SEVERITY, SILENT CLASS FIRST. A hook or production script is SILENT-DEGRADE
-- (fails on the host that PUSHES, with no error); a fixture is LOUD-FAIL
-- (fails by name where it RUNS). A tally that mixes them hides the dangerous
-- half, so silent-degrade is counted first.
--
-- LIMITS, so nobody reads the count as complete: a PATH-dependent tool
-- identity (ugrep installed as `grep`) and a locked login keychain are RUNTIME
-- facts no source scan can see. A green run means "no known idiom in the
-- source", never "portable".
--
-- WHAT THE PORT CHANGES. (1) Speed: measured on yoga 2026-10-09 the .sh took
-- 21,272 ms (one grep fork per rg candidate, awk+grep per file); this reads
-- every file once in-process. (2) Output: stdout is ONE line, the verdict,
-- `portability-idioms: silent-degrade=N loud-fail=M (advisory)` — the runner
-- requires the ` (advisory)` suffix — and the per-hit lines and the limits
-- note go to stderr, so a consumer reads the verdict as a value instead of
-- `| head -1`. The entries themselves are byte-identical to the .sh's.
--
-- TILLANDSIAS_PORTABILITY_ROOT scopes the scan to another tree, for the
-- fixture's CONSTRUCTED controls (1135-z8gn: a control that needs the live
-- tree to stay broken is not a control).

local root_env = env.get("TILLANDSIAS_PORTABILITY_ROOT")
local ROOT = (root_env and root_env ~= "") and root_env or nil
local function rooted(rel) if ROOT then return ROOT .. "/" .. rel end return rel end

-- ── the population: scripts/**/*.sh and build.sh, sorted (find | sort -u) ───
local files, seen = {}, {}
local function add(rel) if not seen[rel] then seen[rel] = true; files[#files + 1] = rel end end
do
    local base = rooted("scripts")
    local ok_w, walked = pcall(fs.walk, base)
    if ok_w then
        for _, p in ipairs(walked) do
            if p:match("%.sh$") then add("scripts/" .. p:sub(#base + 2)) end
        end
    end
    if pcall(fs.read, rooted("build.sh")) then add("build.sh") end
end
table.sort(files)

local function has(s, needle) return s:find(needle, 1, true) ~= nil end

-- COMMENTS ARE NOT CODE: every idiom is DISCUSSED in the comments of the file
-- that fixed it, and counting those is the false-accusation shape this repo has
-- been bitten by three times (599-w5jd, 1087-h2z9, 823-u5zf). And JOIN
-- BACKSLASH CONTINUATIONS, or every wrapped fallback chain reads as an
-- unguarded GNU-ism (litmus-stdlib.sh, the sanctioned absorption layer). The
-- reported line number is the FIRST physical line. Same rule as the .sh's awk:
-- a blank line or one whose first field starts with `#` is skipped entirely.
local function code_lines(content)
    local out, pending, start = {}, nil, 0
    local n = 0
    for _, raw in ipairs(text.lines(content)) do
        n = n + 1
        local first = raw:match("^%s*(%S+)")
        if first and first:sub(1, 1) ~= "#" then
            if pending == nil then start = n; pending = raw else pending = pending .. " " .. raw end
            local stripped = pending:gsub("\\%s*$", "")
            if stripped ~= pending then
                pending = stripped
            else
                out[#out + 1] = { start, pending }
                pending = nil
            end
        end
    end
    if pending ~= nil then out[#out + 1] = { start, pending } end
    return out
end

-- A STRING EXECUTED ON A LINUX HOST IS NOT A PORTABILITY DEFECT: anything run
-- through `podman run`, `docker run`, `wsl`, `ssh` or `--exec-guest` is in the
-- REMOTE dialect, which this scan cannot see — so it is skipped, and said to be
-- among the limits above. Same line, or an assignment to a variable this file
-- hands to such a dispatch, TRANSITIVELY (with-nix-builder.sh builds $_script
-- from $_NB_POPULATE_SNIPPET 35 lines before `podman run … -c "$_script"`; a
-- one-hop rule flagged it). Evidence only: each link is a real assignment in
-- the same file; capped at five hops.
local function is_remote_context(t)
    return has(t, "podman run") or has(t, "docker run") or has(t, "wsl.exe")
        or has(t, "wsl ") or has(t, "ssh ") or has(t, "--exec-guest")
end
local VAR_RE = [[\$\{?[A-Za-z_][A-Za-z0-9_]*]]
local function var_names(line, into)
    for _, m in ipairs(text.captures_all(line, "(" .. VAR_RE .. ")")) do
        local tok = (type(m) == "table" and (m[1] or m[0])) or m
        tok = tok:gsub("[%${]", "")
        into[tok] = true
    end
end
local function remote_vars_of(raw_lines)
    local set = {}
    for _, l in ipairs(raw_lines) do
        if is_remote_context(l) or l:find("wsl%.exe") then var_names(l, set) end
    end
    if table.is_empty(set) then return nil end
    for _ = 1, 5 do
        local new = {}
        for v in pairs(set) do
            local re = "^[[:space:]]*(local[[:space:]]+)?" .. v .. [[\+?=]]
            for _, l in ipairs(raw_lines) do
                if text.is_match(l, re) then var_names(l, new) end
            end
        end
        local grew = false
        for v in pairs(new) do if not set[v] then set[v] = true; grew = true end end
        if not grew then break end
    end
    return set
end
-- Only an UNINDENTED `name=…` counts, and `name+=` does not (the .sh's
-- `${1%%=*}` then `##*[!A-Za-z0-9_]` leaves an empty name for `x+=`).
local function assigns_remote_var(t, vars)
    if not t:match("^[A-Za-z_]") or not has(t, "=") then return false end
    local name = t:match("^([^=]*)="):match("([A-Za-z0-9_]*)$")
    return name ~= "" and vars[name] == true
end

-- AN IDIOM INSIDE AN EXPLICIT DIALECT BRANCH IS ALREADY HANDLED
-- (bump-version.sh: `if sed --version | grep -q GNU; then sed -i … else awk …`,
-- whose BSD arm also dodges BSD sed's silent no-op on `0,/re/`). BOUNDED: a
-- probe suppresses the next six lines, never the whole file.
local DIALECT_WINDOW = 6
local function is_dialect_probe(t)
    return (t:find("%-%-version") and t:find("GNU", (t:find("%-%-version")), true))
        or has(t, "grep -q GNU") or has(t, "grep -qi gnu")
        or has(t, "uname -s") or has(t, "_litmus_os") or has(t, "Darwin)")
end

-- HELP TEXT IS NOT AN INVOCATION: a real rg call carries a flag or a quote.
local function looks_like_invocation(t) return has(t, " -") or has(t, "'") or has(t, '"') end
-- rg in COMMAND POSITION, not the letters (`forge `, `.org `, `merge `).
local RG_CMD = [=[(^|[|;&(]|\$\()[[:space:]]*(rg|\$RG)[[:space:]]]=]

local function class_of(f)
    if f:find("/hooks/", 1, true) or f:find("/pre%-push") or f:find("/post%-") then return "silent" end
    if f:find("/test%-") or f:find("/litmus%-") then return "loud" end
    return "silent" -- a production script is silent-degrade by default
end

-- A literal `touch -t` timestamp is a bug only when it means NOW: a stamp at or
-- after today stops meaning "current" the moment the clock passes it (what
-- expired at 06:00 on 2026-09-12 and refused every land on every host). A
-- deliberately OLD stamp is legitimate and stays quiet.
local TODAY = time.iso_utc():sub(1, 8)

local silent, loud = {}, {}
local function flag(f, n, idiom, portable)
    local e = f .. ":" .. n .. ": " .. idiom .. " — " .. portable
    if class_of(f) == "silent" then silent[#silent + 1] = e else loud[#loud + 1] = e end
end

for _, f in ipairs(files) do
    local ok_r, content = pcall(fs.read, rooted(f))
    if ok_r then
        local rvars = remote_vars_of(text.lines(content))
        local dialect_left = 0
        for _, cl in ipairs(code_lines(content)) do
            local n, t = cl[1], cl[2]
            local skip = is_remote_context(t) or (rvars ~= nil and assigns_remote_var(t, rvars))
            if not skip then
                if is_dialect_probe(t) then dialect_left = DIALECT_WINDOW end
                if dialect_left > 0 then
                    dialect_left = dialect_left - 1
                    skip = true
                end
            end
            if not skip then
                if has(t, "sed -i") then
                    if has(t, "sed -i ''") or has(t, 'sed -i ""') then
                        flag(f, n, "sed -i '' (BSD-only; GNU eats the empty arg as the SCRIPT)", "sed EXPR in > tmp && mv tmp in")
                    else
                        flag(f, n, "sed -i (GNU-only; BSD reads the next arg as a backup suffix)", "sed EXPR in > tmp && mv tmp in")
                    end
                end
                -- ONLY the dotted RUNTIME dirs are symlink farms; skills/ is the
                -- canonical tree of real files and grep -r over it is correct.
                if (has(t, "grep -R") or has(t, "grep -r")) and (has(t, ".claude/") or has(t, ".opencode/")
                    or has(t, ".codex/") or has(t, ".gemini/") or has(t, ".github/skills")) then
                    flag(f, n, "grep -R/-r over a symlink farm (BSD does NOT descend symlinked dirs)", "find -L DIR -type f -print0 | xargs -0 grep -l")
                end
                if has(t, "rg") and text.is_match(t, RG_CMD) and looks_like_invocation(t) then
                    if has(t, "< /dev/null") or has(t, "</dev/null") then
                    elseif has(t, " .") or has(t, '"$ROOT"') or has(t, '"$f"') or has(t, "crates") or has(t, "scripts")
                        or has(t, "plan/") or has(t, "openspec") or has(t, "images") then
                    elseif t:sub(-1) == "\\" then
                    else
                        flag(f, n, "rg with no path operand (reads STDIN; BLOCKS FOREVER under a pipe)", 'give it an explicit path, e.g. rg PATTERN "$ROOT"')
                    end
                end
                do
                    local fi = t:find("find ", 1, true)
                    if fi and t:find("-printf", fi + 5, true) then
                        flag(f, n, "find -printf (GNU-only; BSD yields an EMPTY set, silently)", "find ... -exec stat/basename, or -print0 | xargs -0")
                    end
                end
                if has(t, "touch -d") and not (has(t, "touch -t") or has(t, "touch -A")) then
                    flag(f, n, "touch -d (GNU-only)", "touch -t YYYYMMDDhhmm, or plain touch for now")
                end
                if has(t, "touch -t ") then
                    local stamp
                    for s in t:gmatch("touch %-t (%d%d%d%d%d%d%d%d)") do stamp = s end -- the LAST one, as sed's greedy .*
                    if stamp and stamp >= TODAY then
                        flag(f, n, "touch -t " .. stamp .. " — a literal at/after today is a fixture with an EXPIRY DATE", "plain touch (mtime=now) when the file must be CURRENT")
                    end
                end
                -- BSD wc PADS ("       1"), so `[ "$(… | wc -l)" = 1 ]` is false
                -- there; a line that strips whitespace first is already correct.
                if has(t, "wc -l") or has(t, "wc -c") or has(t, "wc -w") then
                    if has(t, "tr -d") or has(t, "tr -s") then
                    elseif has(t, '" = ') or has(t, '" != ') then
                        flag(f, n, 'string-comparing a wc count (BSD PADS: "       1" != "1")', "use -eq / -ne, never = / !=")
                    end
                end
                if has(t, "readlink -f") and not (has(t, "&& pwd") or has(t, "greadlink")) then
                    flag(f, n, "readlink -f (GNU-only on older BSD)", 'cd "$(dirname X)" && pwd')
                end
                -- THREE BSD counterparts: -r EPOCH, -v, and -j/-jf (the parse form
                -- every correct site uses; omitting it accused four working chains).
                if has(t, "date -d ") and not (has(t, "date -r") or has(t, "date -v") or has(t, "date -j")) then
                    flag(f, n, "date -d (GNU-only; BSD uses -v/-r)", "date -r EPOCH, or compute in awk")
                end
                if has(t, "stat -c") and not has(t, "stat -f") then
                    flag(f, n, "stat -c (GNU-only; BSD uses -f)", "wc -c / a stat wrapper in litmus-stdlib.sh")
                end
            end
        end
    end
end

if #silent > 0 then
    log.raw("  SILENT-DEGRADE (fails on the host that PUSHES, with no error):")
    for _, e in ipairs(silent) do log.raw("    " .. e) end
end
if #loud > 0 then
    log.raw("  LOUD-FAIL (fails on the host that RUNS it, by name):")
    for _, e in ipairs(loud) do log.raw("    " .. e) end
end
-- Restated at the point of the count so the number is never read as a verdict.
log.raw("  note: a PATH-dependent tool identity (ugrep/rg installed as grep) and a")
log.raw("  locked login keychain are RUNTIME facts this scan cannot see.")
verdict.advisory(string.format("portability-idioms: silent-degrade=%d loud-fail=%d (advisory)", #silent, #loud))
