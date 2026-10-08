-- @trace order:1528-ekri, order:1059-pb2j
-- @env TILLANDSIAS_LITMUS_MUTATION_DIR
-- @read-env TILLANDSIAS_LITMUS_MUTATION_DIR
--
-- check-litmus-mutation-arms-mutate.lua — PORTED from
-- check-litmus-mutation-arms-mutate.sh, byte for byte. A litmus step whose
-- NAME promises a MUTATION or SABOTAGE must have a COMMAND that performs one.
-- See the .sh's header (kept in git history) for the three instances that
-- motivated this and why it is a standing guard rather than a one-time audit.
--
-- WHAT THE PORT MAKES SLIGHTLY DIFFERENT: the directory is read from
-- TILLANDSIAS_LITMUS_MUTATION_DIR (default openspec/litmus-tests) rather than
-- a positional argument — the runner's `arg` table carries CLI args, but the
-- only non-default caller is this file's own fixture, and an env var is what
-- `-- @read-env` can widen for a fixture's tree outside the repo, the same
-- seam every other port uses. The listing is still NON-recursive (only
-- *.yaml files directly in the directory), matching the shell glob exactly —
-- openspec/litmus-tests/groundtruth/ holds extra .yaml files a recursive walk
-- would wrongly add to the scan.
--
-- `text` has no general regex-gsub, so the two comment/redirect strips the
-- .sh did with awk's gsub are hand-rolled scanners below (strip_comments,
-- strip_redirects) rather than approximated with a second regex pass whose
-- "^" would no longer mean "start of the original string" after the first
-- replacement. Everything else — the boundary-classed verb tests — is a
-- direct regex port; Rust regex's `^`/`$` anchor to the whole string by
-- default, exactly like awk's.
--
-- Grammar (one line on stdout, unchanged legacy):
--   ok:litmus-mutation-arms:0 of <named> named arms, <steps> steps scanned   exit 0
--   violation:litmus-mutation-arm-mutates-nothing:<n>                       exit 1

local dir_env = env.get("TILLANDSIAS_LITMUS_MUTATION_DIR")
local DIR = (dir_env and dir_env ~= "") and dir_env or "openspec/litmus-tests"

local ok_w, walked = pcall(fs.walk, DIR, { suffix = ".yaml" })
walked = (ok_w and walked) or {}
local prefix = DIR:gsub("/$", "") .. "/"
local files = {}
for _, f in ipairs(walked) do
    local rel = f:sub(#prefix + 1)
    if not rel:find("/") then
        files[#files + 1] = f
    end
end

-- ── strip(): the .sh's two gsubs, hand-scanned ──────────────────────────────
local function strip_comments(s)
    local out = {}
    local i, n = 1, #s
    local at_start = true -- "^" or preceded by a space/tab
    while i <= n do
        local c = s:sub(i, i)
        if c == "#" and at_start then
            local j = i
            while j <= n and s:sub(j, j) ~= "\n" do j = j + 1 end
            out[#out + 1] = " "
            i = j
            at_start = false
        else
            out[#out + 1] = c
            at_start = (c == " " or c == "\t")
            i = i + 1
        end
    end
    return table.concat(out)
end

local function try_redirect(s, i, n)
    if s:sub(i, i) ~= ">" then return nil end
    local j = i + 1
    if s:sub(j, j) == ">" then j = j + 1 end
    local k = j
    while k <= n and (s:sub(k, k) == " " or s:sub(k, k) == "\t") do k = k + 1 end
    if s:sub(k, k + 8) == "/dev/null" then return k + 9 end
    if s:sub(k, k) == "&" then
        local m = k + 1
        while m <= n and (s:sub(m, m) == " " or s:sub(m, m) == "\t") do m = m + 1 end
        if s:sub(m, m) == "2" then return m + 1 end
    end
    return nil
end

local function strip_redirects(s)
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local nextpos = try_redirect(s, i, n)
        if nextpos then
            out[#out + 1] = " "
            i = nextpos
        else
            out[#out + 1] = s:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(out)
end

local function strip(s)
    return strip_redirects(strip_comments(s))
end

-- ── mutates(): the boundary-classed verb tests, straight regex ports ───────
local B = "(^|[^A-Za-z0-9_./-])"
local E = "([^A-Za-z0-9_-]|$)"
local SIMPLE = "(tee|cp|mv|rm|chmod|chown|install|mkdir|touch|trap|mktemp|truncate|patch)"

local function mutates(s)
    if text.is_match(s, B .. SIMPLE .. E) then return true end
    if text.is_match(s, B .. "sed[ \t]+-i" .. E) then return true end
    if text.is_match(s, B .. "git[ \t]+(checkout|restore|stash|apply|revert|reset|init|commit|add|clone)" .. E) then return true end
    if text.is_match(s, B .. "cat[ \t]*<<") then return true end
    if text.is_match(s, B .. "printf[^|;&]*>") then return true end
    if text.is_match(s, B .. "echo[^|;&]*>") then return true end
    if text.is_match(s, ">>") then return true end
    -- DELEGATION COUNTS AS MUTATING (order 147): the boundary class must
    -- include the quote characters, since a litmus command is a YAML scalar.
    if text.is_match(s, "(^|[ \t;&|(\"'])((bash|sh)[ \t]+|\\./)?scripts/[A-Za-z0-9_.-]+\\.sh") then return true end
    return false
end

-- ── the step FSM, state shared across every file in the scan ───────────────
local STEP_DASH = "^[ \t]*-[ \t]*step:[ \t]*"
local STEP_BARE = "^[ \t]*step:[ \t]*"

local name, body = "", ""
local steps, named, bad = 0, 0, 0
local badfile, badname = {}, {}
local current_file = nil

local function flush_step()
    if name == "" then return end
    steps = steps + 1
    if name:find("MUTATION", 1, true) or name:find("SABOTAGE", 1, true) then
        named = named + 1
        local probe = strip(body)
        if not mutates(probe) then
            bad = bad + 1
            badfile[#badfile + 1] = current_file
            badname[#badname + 1] = name:sub(1, 160)
        end
    end
    name, body = "", ""
end

for _, f in ipairs(files) do
    flush_step() -- attribute any pending step to the PREVIOUS file, like the .sh's FNR==1 rule
    current_file = f
    local ok_r, content = pcall(fs.read, f)
    if ok_r then
        for _, line in ipairs(text.lines(content)) do
            local handled = false
            local st1, en1 = text.find(line, STEP_DASH)
            if st1 then
                flush_step()
                name = (line:sub(en1 + 1)):gsub("[ \t]+$", "")
                handled = true
            elseif name == "" then
                local st2, en2 = text.find(line, STEP_BARE)
                if st2 then
                    flush_step()
                    name = (line:sub(en2 + 1)):gsub("[ \t]+$", "")
                    handled = true
                end
            end
            if not handled and name ~= "" then
                body = body .. "\n" .. line
            end
        end
    end
end
flush_step()

if bad > 0 then
    for k = 1, bad do
        log.raw("  " .. badfile[k])
        log.raw("    step: " .. badname[k])
    end
    log.raw("  A step NAMED for a mutation must perform one, or delegate to a")
    log.raw("  fixture that does. The remedy is a RENAME (SOURCE PIN, or what the")
    log.raw("  command actually asserts), not a deletion and not an exception —")
    log.raw("  every instance so far was renamed (1059-pb2j).")
    verdict.emit("violation:litmus-mutation-arm-mutates-nothing:" .. bad, 1)
end

verdict.emit("ok:litmus-mutation-arms:0 of " .. named .. " named arms, " .. steps .. " steps scanned", 0)
