-- @env TILLANDSIAS_SLICE_BOUND_ROOT
-- @read-env TILLANDSIAS_SLICE_BOUND_ROOT
-- @trace spec:ci-release
-- @trace order:797-8dzt, order:830-xsk2, order:1247-jq4e
--
-- check-source-slice-bounds.lua — PORTED from check-source-slice-bounds.sh (the
-- shell-to-lua carried obligation, paid by 1247-jq4e). Same rule, same verdict
-- grammar, same seam (TILLANDSIAS_SLICE_BOUND_ROOT, declared @read-env so a
-- scratch tree is readable):
--
--   tillandsias-plan script run scripts/lua/check-source-slice-bounds.lua
--
-- check-source-slice-bounds.sh — a source-reading test that slices its own file
-- between two SYMBOL NAMES must not be bounded by a symbol that no longer
-- exists. Order 797-8dzt.
--
-- THE DEFECT, measured 2026-08-17 in crates/tillandsias-headless/src/
-- remote_projects.rs. A guard existed to prove the remote-project runner
-- preflights the git image. It sliced its own source like this:
--
--     source.split("fn run_git_image_shell").nth(1)
--           .split("fn run_command_with_timeout").next()
--
-- `fn run_command_with_timeout` is not in that file — the neighbour it named had
-- been renamed or moved. `str::split` on an absent needle does NOT error and
-- does NOT yield nothing: it yields ONE piece, the entire remainder. So the
-- slice ran past the next function, and the assertion was satisfied by a
-- DIFFERENT function's identical preflight call. Deleting the exact line the
-- guard existed to protect left it GREEN. It had been unable to fail for as
-- long as its bound had been missing.
--
-- WHY A STANDING CHECK RATHER THAN THE ONE-TIME AUDIT THE PACKET ASKED FOR. The
-- audit found the corpus otherwise clean: two symbol-bounded slices remain and
-- both resolve. That is exactly the state in which the next rename reintroduces
-- the bug silently, because nothing is watching. An audit answers "is it broken
-- today"; this answers "will I be told when it breaks".
--
-- WHAT IT CHECKS. Every `.split("<needle>")` in a Rust source under crates/
-- whose needle looks like an item declaration (`fn`, `pub fn`, `async fn`,
-- `pub async fn`, `impl`, `struct`, `enum`, `trait`). The needle must appear
-- somewhere in that CRATE's sources. Crate scope, not file scope, is a
-- deliberate under-approximation: a test in main.rs may legitimately slice
-- action_host.rs via include_str!, and this must not accuse it. A needle that
-- matches nowhere in the crate is dead by any reading.
--
-- GRAMMAR — exactly one line:
--
-- ONE DELIBERATE DIFFERENCE. The .sh climbed from each source toward "/" looking
-- for a Cargo.toml, stopping early only at "." — so under an ABSOLUTE root a
-- source outside any crate in it picked the checkout's own Cargo.toml above the
-- root and was judged against the whole checkout. The climb now stops at the
-- root's parent, which is exactly where the .sh stopped for the default
-- relative root ("crates" -> "."), so the live verdict is unchanged.
--
-- THE DECLARATION MATCH (797-8dzt control 2, 830-xsk2). A needle resolves when
-- some line of the crate is, after indentation, zero or more modifier words
-- (`unsafe `, `pub `, `const `...) and then the needle followed by whitespace,
-- `(`, `<` or `{`. A plain substring search would find the needle inside the
-- very `.split("…")` under test and make the guard vacuous.

local ROOT_DIR = env.get("TILLANDSIAS_SLICE_BOUND_ROOT")
if ROOT_DIR == nil or ROOT_DIR == "" then ROOT_DIR = "crates" end
ROOT_DIR = ROOT_DIR:gsub("/+$", "")

local ok_walk, walked = pcall(fs.walk, ROOT_DIR, { suffix = ".rs" })
if not ok_walk or type(walked) ~= "table" or #walked == 0 then
    verdict.emit("ok:source-slice-bounds:0 checked", 0)
end

local function full(p)
    if p:sub(1, #ROOT_DIR + 1) == ROOT_DIR .. "/" then return p end
    return ROOT_DIR .. "/" .. p
end
local function dirname(p)
    local d = p:match("^(.*)/[^/]*$")
    if d == nil then return "." end
    if d == "" then return "/" end
    return d
end

local sources = {}
for _, p in ipairs(walked) do sources[#sources + 1] = full(p) end
table.sort(sources)

local STOP = dirname(ROOT_DIR)
local function crate_of(rs)
    local d = dirname(rs)
    while d ~= "." and d ~= "/" and d ~= STOP do
        if fs.exists(d .. "/Cargo.toml") then return d end
        d = dirname(d)
    end
    return ROOT_DIR
end

-- Lines of every .rs under a crate directory, read once per crate.
local crate_lines = {}
local function lines_of(crate)
    if crate_lines[crate] then return crate_lines[crate] end
    local all = {}
    for _, rs in ipairs(sources) do
        if rs:sub(1, #crate + 1) == crate .. "/" then
            local okr, body = pcall(fs.read, rs)
            if okr and type(body) == "string" then
                for _, line in ipairs(text.lines(body)) do all[#all + 1] = line end
            end
        end
    end
    crate_lines[crate] = all
    return all
end

local function declares(line, needle)
    local s = line:gsub("^%s+", "")
    while true do
        if s:sub(1, #needle) == needle then
            local c = s:sub(#needle + 1, #needle + 1)
            if c ~= "" and c:match("[%s(<{]") then return true end
        end
        local rest = s:match("^[%a_]+ (.*)$")
        if rest == nil then return false end
        s = rest
    end
end

-- The needle shapes the .sh's grep -oE accepted.
local KINDS = { "fn", "pub fn", "async fn", "pub async fn", "impl", "struct", "enum", "trait" }
local function bound_needle(lit)
    for _, k in ipairs(KINDS) do
        if lit:sub(1, #k + 1) == k .. " " and lit:sub(#k + 2):match("^[%w_:<>]+$") then return lit end
    end
    return nil
end

local checked, violations = 0, {}
for _, rs in ipairs(sources) do
    local okr, body = pcall(fs.read, rs)
    if okr and type(body) == "string" then
        local crate = nil
        for _, line in ipairs(text.lines(body)) do
            for lit in line:gmatch('%.split%("([^"]*)"%)') do
                local needle = bound_needle(lit)
                if needle then
                    checked = checked + 1
                    crate = crate or crate_of(rs)
                    local found = false
                    for _, l in ipairs(lines_of(crate)) do
                        if declares(l, needle) then found = true; break end
                    end
                    if not found then
                        violations[#violations + 1] = "  " .. rs .. ": slice bound \"" .. needle .. "\" matches nothing in " .. crate .. " — split() returns the WHOLE remainder, so this assertion has silently widened"
                    end
                end
            end
        end
    end
end

if #violations > 0 then
    for _, v in ipairs(violations) do log.raw(v) end
    log.raw("  CAUSE: str::split on an absent needle yields ONE piece — the entire remainder — so the window runs past its intended end and the assertion is satisfied by unrelated code.")
    log.raw("  REMEDY: bound the slice by structure (the item's own closing brace) rather than by a neighbour's NAME, or update the bound and re-run the mutation control that proves the assertion can still fail.")
    verdict.emit("violation:source-slice-bounds:" .. #violations, 1)
end
verdict.emit("ok:source-slice-bounds:" .. checked .. " checked", 0)
