-- @env TILLANDSIAS_ENTRYPOINT_GLOB
-- @trace spec:runtime-diagnostics-stream, spec:logging-accountability
-- @trace order:702-6jza, order:1526-gv3t
--
-- check-backgrounded-jobs-redirect-stderr.lua — PORTED from
-- check-backgrounded-jobs-redirect-stderr.sh, byte for byte. ORDER 702-6jza
-- D4: refuse a BACKGROUNDED invocation in an agent entrypoint that redirects
-- only fd 1 — `cmd >>/tmp/forge-lifecycle.log &` leaves fd 2 on the container
-- tty, where it writes over a live agent TUI.
--
-- TILLANDSIAS_ENTRYPOINT_GLOB is a single shell glob of the form
-- "<dir>/<pattern>" (default "images/default/entrypoint-forge-*.sh"), and the
-- .sh's `files=($SCAN_GLOB)` expands it NON-recursively — only direct children
-- of <dir>. This port walks <dir> with fs.walk and keeps only paths with no
-- further '/' past it, which is the same restriction, and matches the
-- basename against the glob's '*'-pieces (the only wildcard construct any
-- caller uses) compiled to a regex.
--
-- Verdict grammar, one line on stdout (unchanged):
--   ok:backgrounded-stderr:<n> site(s) checked      exit 0
--   violation:backgrounded-stderr:<n>               exit 1
--   blocked:no-entrypoints-matched:<glob>            exit 2
local scan_glob = env.get("TILLANDSIAS_ENTRYPOINT_GLOB")
if scan_glob == nil or scan_glob == "" then
    scan_glob = "images/default/entrypoint-forge-*.sh"
end

local dir, pat = scan_glob:match("^(.*)/([^/]*)$")
if not dir then
    dir, pat = ".", scan_glob
end

local function glob_to_regex(p)
    local pieces = {}
    local start = 1
    while true do
        local i = p:find("*", start, true)
        if not i then
            pieces[#pieces + 1] = p:sub(start)
            break
        end
        pieces[#pieces + 1] = p:sub(start, i - 1)
        start = i + 1
    end
    local escaped = {}
    for i, piece in ipairs(pieces) do escaped[i] = text.escape(piece) end
    return "^" .. table.concat(escaped, ".*") .. "$"
end

local PAT_RE = glob_to_regex(pat)

local candidates = {}
local ok_walk, files = pcall(fs.walk, dir)
if ok_walk then
    local prefix = (dir:gsub("/+$", "")) .. "/"
    for _, f in ipairs(files) do
        if f:sub(1, #prefix) == prefix then
            local rest = f:sub(#prefix + 1)
            if not rest:find("/", 1, true) and text.is_match(rest, PAT_RE) then
                candidates[#candidates + 1] = f
            end
        end
    end
end

if #candidates == 0 then
    verdict.emit("blocked:no-entrypoints-matched:" .. scan_glob, 2)
end

-- A backgrounded line is one ending in `&` (not `&&`). Of those, flag any that
-- redirects stdout without also redirecting stderr.
local BACKGROUNDED_REDIRECT = [=[(>>?)[[:space:]]*[^[:space:]|&]+.*[^&]&[[:space:]]*$]=]

local checked = 0
local bad = {}
for _, f in ipairs(candidates) do
    local ok, content = pcall(fs.read, f)
    if ok then
        local lineno = 0
        for _, line in ipairs(text.lines(content)) do
            lineno = lineno + 1
            if text.is_match(line, BACKGROUNDED_REDIRECT) then
                checked = checked + 1
                if not text.contains(line, "2>") then
                    bad[#bad + 1] = f .. ":" .. lineno .. ":" .. line
                end
            end
        end
    end
end

if #bad > 0 then
    for _, b in ipairs(bad) do log.raw("  fd1-only backgrounded job: " .. b) end
    log.raw("  A backgrounded job that redirects only stdout leaves fd 2 on the")
    log.raw("  container tty, where it writes over a live agent TUI (702-6jza D4).")
    log.raw("  REMEDY: >>/tmp/forge-lifecycle.log 2>&1 &")
    verdict.emit("violation:backgrounded-stderr:" .. #bad, 1)
end

verdict.emit("ok:backgrounded-stderr:" .. checked .. " site(s) checked", 0)
