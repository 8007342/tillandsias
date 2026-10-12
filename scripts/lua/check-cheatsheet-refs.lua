-- @trace order:1570-k4fx, spec:cheatsheet-tooling, spec:cheatsheet-mcp-server, spec:spec-traceability
--
-- check-cheatsheet-refs.lua — every cheatsheet reference resolves. PORTED from
-- check-cheatsheet-refs.sh (1570-k4fx), with NO host tool at all.
--
-- Walks:
--   * `@cheatsheet <path>[, <path>]...` annotations in cheatsheets/**/*.md,
--     src-tauri/src/**/*.rs, images/default/**/*.sh and
--     images/default/**/Containerfile*;
--   * `## See also` bullets in cheatsheets/**/*.md shaped `- <path>.md ...` or
--     `- ` + backtick + `<path>.md` + backtick + ` ...`, scoped from the
--     `## See also` heading to the next `## ` heading.
-- A path resolves if cheatsheets/<path> or <repo>/<path> is a file and it ends
-- in `.md`; both the cheatsheets-relative and the repo-relative form are
-- accepted.
--
-- WHY THE PORT HAS NO TOOL. The .sh hard-required ripgrep: host, else the
-- tillandsias-builder toolbox, else exit 2 — and a gate with no rg either
-- refused ~20 min in (esmeraldinha, WSL2, 2026-09-12: LAND_EXIT=3 over zero
-- references examined), or, with rg present but broken, matched nothing and
-- PASSED having examined nothing (1138-bb5r). rg with no path operand also
-- read stdin and hung the gate for 43 min under a pipe (macbookair,
-- 2026-09-12). Reading the files in-process removes all three: there is no
-- tool to be absent, broken or waiting on stdin.
--
-- AND THE WINDOWS PARSE. The .sh split rg's `<file>:<line>:<match>` output and
-- a `C:/` drive letter shifted every field (yolanda 2026-09-06: 491 of 577
-- reported broken, all of whose targets existed). There is no text to parse
-- here: the file, line and match are values.
--
-- WHAT IT CANNOT SEE: inline markdown links `[x](path.md)` are not references
-- to it (1300-k7wq tracks that); only the two shapes above count. Files rg
-- would skip as gitignored or hidden are also skipped here only if fs.walk
-- skips them — the measured parity is on the reference COUNT and the broken
-- set, recorded on the closing event.
--
-- Verdicts:
--   ok:cheatsheet-refs:<n>                                    exit 0
--   violation:cheatsheet-refs-broken:<k>:of:<n>               exit 1  (each broken ref on stderr)
--   blocked:cheatsheet-refs:no-cheatsheets-dir                exit 2  (a broken checkout, never a skip)

local CHEATSHEETS = "cheatsheets"
if not fs.exists(CHEATSHEETS) then
    verdict.emit("blocked:cheatsheet-refs:no-cheatsheets-dir", 2,
        "error: cheatsheets directory not found at the repository root")
end

local function walk(dir)
    local ok_w, w = pcall(fs.walk, dir)
    if not ok_w then return {} end
    table.sort(w)
    return w
end

-- The @cheatsheet population, in the .sh's glob terms.
local annotated = {}
for _, p in ipairs(walk(CHEATSHEETS)) do if p:match("%.md$") then annotated[#annotated + 1] = p end end
for _, p in ipairs(walk("src-tauri/src")) do if p:match("%.rs$") then annotated[#annotated + 1] = p end end
for _, p in ipairs(walk("images/default")) do
    local leaf = p:match("([^/]+)$")
    if p:match("%.sh$") or leaf:match("^Containerfile") then annotated[#annotated + 1] = p end
end
table.sort(annotated)

local ANNOT = [=[@cheatsheet[[:space:]]+([A-Za-z0-9_./-]+\.md(?:[[:space:]]*,[[:space:]]*[A-Za-z0-9_./-]+\.md)*)]=]
local function cap1(m) return (type(m) == "table" and (m[1] or m[0])) or m end

local refs = {} -- { file, line, path }
for _, f in ipairs(annotated) do
    local ok_r, c = pcall(fs.read, f)
    if ok_r and c:find("@cheatsheet", 1, true) then
        local n = 0
        for _, l in ipairs(text.lines(c)) do
            n = n + 1
            if l:find("@cheatsheet", 1, true) then
                for _, m in ipairs(text.captures_all(l, ANNOT)) do
                    for part in (cap1(m) .. ","):gmatch("([^,]*),") do
                        local p = text.trim(part)
                        if p ~= "" then refs[#refs + 1] = { f, n, p } end
                    end
                end
            end
        end
    end
end

-- `## See also` bullets, per cheatsheet, section-scoped.
for _, f in ipairs(walk(CHEATSHEETS)) do
    if f:match("%.md$") then
        local ok_r, c = pcall(fs.read, f)
        if ok_r and c:find("## See also", 1, true) then
            local n, in_section = 0, false
            for _, l in ipairs(text.lines(c)) do
                n = n + 1
                if l:match("^## See also%s*$") then
                    in_section = true
                elseif in_section and l:match("^## ") then
                    in_section = false
                elseif in_section then
                    local p = l:match("^%-%s+`([A-Za-z0-9_./%-]+%.md)`") or l:match("^%-%s+([A-Za-z0-9_./%-]+%.md)")
                    if p then refs[#refs + 1] = { f, n, p } end
                end
            end
        end
    end
end

local function resolves(target)
    target = text.trim(target)
    if target == "" or not target:match("%.md$") then return false end
    return fs.exists(CHEATSHEETS .. "/" .. target) or fs.exists(target)
end

local broken = {}
for _, r in ipairs(refs) do
    if not resolves(r[3]) then broken[#broken + 1] = r[1] .. ":" .. r[2] .. ": " .. r[3] end
end
if #broken > 0 then
    verdict.emit("violation:cheatsheet-refs-broken:" .. #broken .. ":of:" .. #refs, 1,
        "Broken cheatsheet references (" .. #broken .. " of " .. #refs .. " checked):\n  " .. table.concat(broken, "\n  "))
end
verdict.ok("cheatsheet-refs", #refs)
