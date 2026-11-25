-- @trace order:1470-v67y, order:2221-rfaa, spec:methodology-accountability
-- @env TILLANDSIAS_AFFORDANCE_BASE TILLANDSIAS_GATE_DIFF_BASE
--
-- check-refusal-affordance-added.lua — a NEW refusal must say why it refused
-- and what would make it not a refusal (1247-amcu criteria 1 and 2). PORTED
-- from check-refusal-affordance-added.sh (2221-rfaa): same grammar, same exit
-- codes, same windows, same stderr blocks.
--
-- THE OPERATOR RULING (2026-09-17): "Errors alone are not useful, they should
-- all include the 'affordance' of why this was an error, and what would make
-- this not an error." The fleet is agents: a bare `violation:<token>` gives an
-- agent no next action, so it either stops or invents one.
--
-- WHAT COUNTS AS A REFUSAL: a line that EMITS (echo / printf / say / die /
-- _error / fail / warn / log) a `refused:`, `blocked:` or `violation:` token.
-- A line that only MATCHES one (case arms, grep patterns, comments) emits
-- nothing.
--
-- WHAT COUNTS AS ITS AFFORDANCE, from BACK lines before the verdict line to
-- WINDOW lines after it:
--   * a call to an affordance helper: any word containing `afford` followed by
--     whitespace (the fleet convention is `_afford "<why>" "<remedy>"`); or
--   * both a why and a remedy in the text: `why` and one of `remedy`,
--     `WHAT TO DO`, `to clear`, `fix:` (case-insensitive); or
--   * `affordance-ok: <reason>` on the verdict line or the line above it, for
--     a token only a PROGRAM reads. The reason is required.
--
-- DIFF-SCOPED: only lines this change ADDS (tracked and untracked scripts/*.sh,
-- build.sh). Fixtures (scripts/test-*.sh) print verdicts as EXPECTATIONS and
-- are skipped. Lua deciders are not in scope (the .sh was not either).
--
--   ok:refusal-affordance-added:<n> checked
--   violation:refusal-affordance-added:<n>        (rc 1; each site on stderr)
--   ok:refusal-affordance-added:base-unavailable  (no base ref; nothing judged)
--
-- --audit: every verdict SITE in the standing tree, one line each
--   covered <file>:<line> <token>   |   bare <file>:<line> <token>
-- then `audit:refusal-affordance:covered=<c> bare=<b> sites=<n>`, PER SITE,
-- then `ok:refusal-affordance-audit:<n> sites` (the runner's house verdict).
--
-- The repo is the CALLER's checkout (git rev-parse in the caller's PWD), as the
-- .sh's was the checkout its own copy sat in. Files are read with `cat` there.
-- The ERE tests run through expect.matches (Rust regex), so the patterns are
-- the .sh's own.

local WINDOW, BACK = 8, 3
local EMIT = "(echo|printf|say|die|_error|fail|warn|log)[^#]*(refused|blocked|violation):[a-z0-9]"

local function run(argv, ms)
    return proc.run({ argv = argv, timeout_ms = ms or 120000 })
end
local function okr(r) return r.status == "exited" and r.code == 0 end
local function rx(s, pat) return (pcall(expect.matches, s, pat)) end
local function split(s)
    local t = {}
    for l in ((s or "") .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
    if t[#t] == "" then t[#t] = nil end
    return t
end

local top = run({ "git", "rev-parse", "--show-toplevel" }, 30000)
local ROOT = text.trim(top.stdout or "")
if not okr(top) or ROOT == "" then
    verdict.emit("ok:refusal-affordance-added:base-unavailable", 0,
        "  note: not inside a git checkout — added-line enforcement skipped")
end
local function git(...) local a = { "git", "-C", ROOT }; for _, v in ipairs({ ... }) do a[#a + 1] = v end; return run(a) end

local cache = {}
local function file_lines(f)
    if cache[f] == nil then
        local r = run({ "cat", ROOT .. "/" .. f }, 30000)
        cache[f] = okr(r) and split(r.stdout) or false
    end
    return cache[f]
end
-- grep reads LINE BY LINE: a pattern never spans a newline. So each window
-- is tested line by line, never as one joined string ([[:space:]] would
-- otherwise cross the newline; an empty `affordance-ok:` would pass).
local function any_line(L, a, b, pat)
    for i = math.max(a, 1), math.min(b, #L) do
        if rx(L[i], pat) then return true end
    end
    return false
end

-- covered(L, ln): the site at ln carries an affordance.
local function covered(L, ln)
    if any_line(L, ln > 1 and ln - 1 or 1, ln, "affordance-ok:[[:space:]]*[^[:space:]]") then return true end
    local a, b = ln > BACK and ln - BACK or 1, ln + WINDOW
    if any_line(L, a, b, "[A-Za-z_]*afford[A-Za-z_]*[[:space:]]") then return true end
    if any_line(L, a, b, "(?i)why") and any_line(L, a, b, "(?i)remedy|what to do|to clear|fix:") then return true end
    return false
end

-- emits(line): the line emits a refusal verdict (a comment emits nothing).
local function emits(line)
    local t = line:gsub("^%s+", "")
    if t:sub(1, 1) == "#" then return false end
    return rx(t, EMIT)
end

-- token(line): grep -oE '(refused|blocked|violation):[a-z0-9][a-z0-9:_.-]*', first hit.
local function token(line)
    local best, bpos = "", nil
    for _, w in ipairs({ "refused", "blocked", "violation" }) do
        local s, e = line:find(w .. ":[a-z0-9][a-z0-9:_.%-]*")
        if s and (not bpos or s < bpos) then bpos = s; best = line:sub(s, e) end
    end
    return best
end

local function in_scope(f)
    if f:match("^scripts/test%-[^/]*%.sh$") or (f:match("^scripts/test%-") and f:match("%.sh$")) then return false end
    if f == "build.sh" then return true end
    return f:match("^scripts/.*%.sh$") ~= nil
end

local AUDIT = false
for i = 1, #arg do if arg[i] == "--audit" then AUDIT = true end end

if AUDIT then
    local c, b = 0, 0
    local ls = git("ls-files", "--", "scripts/*.sh", "build.sh")
    for _, f in ipairs(split(ls.stdout)) do
        if in_scope(f) then
            local L = file_lines(f)
            if L then
                for ln, line in ipairs(L) do
                    -- the .sh pre-filtered with grep -nE EMIT over raw lines,
                    -- then emits(); a cheap substring screen keeps that order.
                    if (line:find("refused:", 1, true) or line:find("blocked:", 1, true) or line:find("violation:", 1, true))
                        and rx(line, EMIT) and emits(line) then
                        local tok = token(line)
                        if covered(L, ln) then c = c + 1; out.line("covered " .. f .. ":" .. ln .. " " .. tok)
                        else b = b + 1; out.line("bare " .. f .. ":" .. ln .. " " .. tok) end
                    end
                end
            end
        end
    end
    -- The .sh's summary line is kept verbatim (rank-refusal-hits.sh greps for
    -- it); the runner needs a house verdict, so ok: follows it. No caller
    -- reads the summary as the LAST line (2221-rfaa).
    out.line("audit:refusal-affordance:covered=" .. c .. " bare=" .. b .. " sites=" .. (c + b))
    verdict.emit("ok:refusal-affordance-audit:" .. (c + b) .. " sites", 0)
end

local base = env.get("TILLANDSIAS_AFFORDANCE_BASE") or ""
if base == "" then base = env.get("TILLANDSIAS_GATE_DIFF_BASE") or "" end
if base == "" then base = "origin/linux-next" end
-- `^{commit}` (2241-f8jg): a bare 40-hex "verifies" with no such object here,
-- and every diff after it would fail quietly and judge nothing.
if not okr(git("rev-parse", "--verify", "--quiet", base .. "^{commit}")) then
    verdict.emit("ok:refusal-affordance-added:base-unavailable", 0,
        "  note: base ref '" .. base .. "' unavailable — added-line enforcement skipped")
end

local seen, files = {}, {}
for _, src in ipairs({
    git("diff", "--name-only", "--diff-filter=AM", base, "--", "scripts/*.sh", "build.sh").stdout,
    git("ls-files", "--others", "--exclude-standard", "--", "scripts/*.sh", "build.sh").stdout,
}) do
    for _, f in ipairs(split(src)) do
        if f ~= "" and not seen[f] then seen[f] = true; files[#files + 1] = f end
    end
end
table.sort(files)
local tracked = {}
for _, f in ipairs(split(git("ls-files", "--", "scripts/*.sh", "build.sh").stdout)) do tracked[f] = true end

local checked, violations = 0, 0
for _, f in ipairs(files) do
    local L = file_lines(f)
    if L and in_scope(f) then
        checked = checked + 1
        local added = {}
        if tracked[f] then
            local n = 0
            for _, l in ipairs(split(git("diff", "-U0", base, "--", f).stdout)) do
                if l:sub(1, 2) == "@@" then
                    n = tonumber(l:match("^@@ %S+ %+(%d+)")) or 0
                elseif l:sub(1, 3) == "+++" then
                elseif l:sub(1, 1) == "+" then added[#added + 1] = n; n = n + 1
                end
            end
        else
            for i = 1, #L do added[#added + 1] = i end
        end
        for _, ln in ipairs(added) do
            local line = L[ln] or ""
            if emits(line) and not covered(L, ln) then
                violations = violations + 1
                log.raw("REFUSED: " .. f .. ":" .. ln .. " adds a refusal with no affordance: " .. token(line) .. "\n"
                    .. "  why: a bare verdict tells an agent it is stuck without telling it how to stop\n"
                    .. "       being stuck (operator ruling 2026-09-17, 1247-amcu).\n"
                    .. "  remedy: within " .. BACK .. " lines before it or " .. WINDOW .. " after, say WHY (the rule that\n"
                    .. "       refused) and the REMEDY (what clears it). The fleet helper, if the script\n"
                    .. "       lacks it: _afford() { printf '  why: %s\\n  remedy: %s\\n' \"$1\" \"$2\" >&2; }\n"
                    .. "       then: _afford \"<why>\" \"<remedy>\". For a token only a PROGRAM reads,\n"
                    .. "       mark the line instead: # affordance-ok: <which caller prints the remedy>.\n")
            end
        end
    end
end

if violations > 0 then
    log.raw("  why: each site above emits a refusal verdict with no why/remedy near it (1247-amcu)\n"
        .. "  remedy: add the affordance each REFUSED block names, then re-run this check\n")
    verdict.emit("violation:refusal-affordance-added:" .. violations, 1)
end
verdict.emit("ok:refusal-affordance-added:" .. checked .. " checked", 0)
