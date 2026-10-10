-- @trace order:837-et6t, order:795-zshi, order:1576-yqmc, spec:vsock-exec-authz
-- @env TILLANDSIAS_EXEC_ARGV_SCAN_ROOT
-- @read-env TILLANDSIAS_EXEC_ARGV_SCAN_ROOT
--
-- check-exec-argv-vector-workarounds.lua — PORTED from
-- check-exec-argv-vector-workarounds.sh (carried obligation shell->lua, paid
-- by 1576-yqmc). The verbatim-argv arm (spec vsock-exec-authz §4) retired two
-- host-side escaping workarounds that existed ONLY to survive argv being
-- flattened into a shell string. A deletion with no guard against
-- re-introduction gets undone by whoever next hits the quoting problem.
--
-- THIS SCANS FOR DEFINITIONS, NOT MENTIONS. `argv_survives_wt_reparse` and
-- `wt_safe_title` are named in comments that record why they went away; those
-- comments are institutional memory and must not make the gate red. A
-- `fn <name>` definition is what would actually bring a workaround back.
-- 634-39ik: this asserts the ABSENCE of named symbols, never how today's
-- source is spelled. NOT SCANNED, deliberately: `build_exec_guest_shell_cmd`
-- (838-48ca kept it, scoped to genuine shell requests).
--
-- Root: arg[1] (default "."), or TILLANDSIAS_EXEC_ARGV_SCAN_ROOT, the TEST
-- SEAM the litmus's hermetic arms point at a `mktemp -d` tree (@read-env widens
-- fs.walk/fs.read under it).
-- Verdicts (unchanged grammar and exit codes):
--   ok:exec-argv-workarounds-absent:<n> checked                  exit 0
--   violation:exec-argv-workaround-reintroduced:<n symbols>      exit 1
--   blocked:no-such-root:<root>                                  exit 2
-- Each hit goes to stderr as "  reintroduced: <file>:<line>:<text>", as the
-- .sh's `grep -rn` lines did.

local RETIRED_SYMBOLS = { "argv_survives_wt_reparse", "wt_safe_title" }

local root = env.get("TILLANDSIAS_EXEC_ARGV_SCAN_ROOT")
if root == nil or root == "" then
    root = arg[1] or "."
end

local ok_walk, files = pcall(fs.walk, root)
if not ok_walk or files == nil then
    verdict.emit("blocked:no-such-root:" .. root, 2)
    return
end

local sources = {}
for _, f in ipairs(files) do
    if f:sub(-3) == ".rs" then
        local ok, content = pcall(fs.read, f)
        if ok and content then sources[#sources + 1] = { f, content } end
    end
end

local violations = 0
for _, sym in ipairs(RETIRED_SYMBOLS) do
    -- `fn <sym>` catches a plain fn, a pub fn, a method and a const fn alike.
    local re = "fn[[:space:]]+" .. sym .. "\\b"
    local hit = false
    for _, src in ipairs(sources) do
        local lineno = 0
        for _, line in ipairs(text.lines(src[2])) do
            lineno = lineno + 1
            if text.is_match(line, re) then
                log.raw(("  reintroduced: %s:%d:%s"):format(src[1], lineno, line))
                hit = true
            end
        end
    end
    if hit then violations = violations + 1 end
end

if violations ~= 0 then
    verdict.emit(("violation:exec-argv-workaround-reintroduced:%d"):format(violations), 1)
    return
end
verdict.emit(("ok:exec-argv-workarounds-absent:%d checked"):format(#RETIRED_SYMBOLS), 0)
