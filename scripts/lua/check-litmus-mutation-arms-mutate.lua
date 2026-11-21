-- @env PWD
-- @trace order:1059-pb2j, order:147
--
-- check-litmus-mutation-arms-mutate.lua — a litmus step whose NAME promises a
-- MUTATION or SABOTAGE must have a COMMAND that performs one. (Ported from
-- scripts/check-litmus-mutation-arms-mutate.sh, the shell-to-lua item carried
-- by order 2166-yq4w; the three instances that motivated it — 1029-5wvd,
-- 1033-ev5r, 1059-pb2j — are told in `git log -- scripts/check-litmus-mutation-arms-mutate.sh`.)
--
-- The remedy is a RENAME (SOURCE PIN, or what the command asserts), so this
-- refuses the NAME, never the technique. DELEGATION COUNTS: a command that runs
-- scripts/<x>.sh (bare, quoted, or via bash/sh/./) mutates inside that fixture.
-- Redirections to /dev/null or fd 2 and shell comments do not count.
--
-- Same rules, regexes, step parsing and verdicts as the .sh's awk:
--   ok:litmus-mutation-arms:0 of <named> named arms, <steps> steps scanned   exit 0
--   violation:litmus-mutation-arm-mutates-nothing:<n>                        exit 1
-- with each offending file and step on stderr.
--
-- Usage: tillandsias-plan script run scripts/lua/check-litmus-mutation-arms-mutate.lua [-- <dir>]
-- (default openspec/litmus-tests). The directory may lie outside the repository
-- (the fixture passes a temp dir), so it is listed and read through child
-- processes in the caller's PWD, not fs.* (confined to the runner's root).

local function caller_dir()
    local d = env.get("PWD")
    if d ~= nil and d ~= "" and (d:sub(1, 1) == "/" or d:match("^%a:[/\\]")) then return d end
    return nil
end
local CALLER = caller_dir()
local function run(argv)
    return proc.run({ argv = argv, cwd = CALLER, timeout_ms = 60000 })
end

local DIR = arg[1] or "openspec/litmus-tests"

-- strip(): the awk's two gsubs. Comments: a `#` after a blank,
-- to end of line, replaced (with that blank) by one space. Redirections:
-- `>`/`>>` to /dev/null or to &2.
local function strip(s)
    local out = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        -- awk's `^` anchors the whole BODY, which always starts with "\n", so
        -- only a blank-preceded `#` ever matched; keep exactly that.
        line = line:gsub("[ \t]#.*$", " ")
        out[#out + 1] = line
    end
    s = table.concat(out, "\n")
    s = s:gsub(">>?[ \t]*/dev/null", " "):gsub(">>?[ \t]*&[ \t]*2", " ")
    return s
end

local B = "(^|[^A-Za-z0-9_./-])"
local E = "([^A-Za-z0-9_-]|$)"
local SIMPLE = "(tee|cp|mv|rm|chmod|chown|install|mkdir|touch|trap|mktemp|truncate|patch)"
local RULES = {
    B .. SIMPLE .. E,
    B .. "sed[ \\t]+-i" .. E,
    B .. "git[ \\t]+(checkout|restore|stash|apply|revert|reset|init|commit|add|clone)" .. E,
    B .. "cat[ \\t]*<<",
    B .. "printf[^|;&]*>",
    B .. "echo[^|;&]*>",
    ">>",
    "(^|[ \\t;&|(\"'])((bash|sh)[ \\t]+|\\./)?scripts/[A-Za-z0-9_.-]+\\.sh",
}
local function mutates(s)
    for _, re in ipairs(RULES) do
        if text.is_match(s, re) then return true end
    end
    return false
end

local ls = run({ "ls", "-1", DIR })
local files = {}
if ls.status == "exited" and ls.code == 0 then
    for n in (ls.stdout or ""):gmatch("[^\n]+") do
        if n:match("%.yaml$") then files[#files + 1] = DIR .. "/" .. n end
    end
end

local steps, named, bad = 0, 0, {}
local name, body, file = "", "", nil
local function flush_step()
    if name == "" then return end
    steps = steps + 1
    -- case-sensitive: the corpus shouts them
    if name:find("MUTATION", 1, true) or name:find("SABOTAGE", 1, true) then
        named = named + 1
        if not mutates(strip(body)) then
            bad[#bad + 1] = { file = file, name = name:sub(1, 160) }
        end
    end
    name, body = "", ""
end

for _, f in ipairs(files) do
    flush_step(); file = f
    local r = run({ "cat", f })
    local content = r.stdout or ""
    if content ~= "" and content:sub(-1) ~= "\n" then content = content .. "\n" end
    for line in content:gmatch("([^\n]*)\n") do
        local rest = line:match("^[ \t]*%-[ \t]*step:[ \t]*(.*)$")
        if not rest and name == "" then rest = line:match("^[ \t]*step:[ \t]*(.*)$") end
        if rest then
            flush_step()
            name = rest:gsub("[ \t]+$", "")
        elseif name ~= "" then
            body = body .. "\n" .. line
        end
    end
end
flush_step()

if #bad > 0 then
    local detail = {}
    for _, b in ipairs(bad) do
        detail[#detail + 1] = "  " .. b.file
        detail[#detail + 1] = "    step: " .. b.name
    end
    detail[#detail + 1] = "  A step NAMED for a mutation must perform one, or delegate to a"
    detail[#detail + 1] = "  fixture that does. The remedy is a RENAME (SOURCE PIN, or what the"
    detail[#detail + 1] = "  command actually asserts), not a deletion and not an exception —"
    detail[#detail + 1] = "  every instance so far was renamed (1059-pb2j)."
    verdict.emit("violation:litmus-mutation-arm-mutates-nothing:" .. #bad, 1, table.concat(detail, "\n"))
end
verdict.emit("ok:litmus-mutation-arms:0 of " .. named .. " named arms, " .. steps .. " steps scanned", 0)
