-- @trace order:956-llei, order:799-tb7q, order:1428-3kdu
--
-- check-no-end-user-brew-instruction.lua — PORTED from
-- check-no-end-user-brew-instruction.sh (carried obligation shell->lua, paid
-- by 1428-3kdu). The shipped diagnostics must never tell an END USER to
-- `brew install` a developer tool (799-tb7q). Reads only EXECUTABLE lines: a
-- guard that matched the comment documenting the removal punished explaining
-- removals (cheatsheet: grep-REDS-on-comments).
--
-- Usage: tillandsias-plan script run scripts/lua/check-no-end-user-brew-instruction.lua -- <script>...
-- Verdicts (same exit codes; the runtime's verdict grammar forbids a FAIL:
-- prefix, so the two refusals are renamed — the one caller, the litmus and its
-- mutation fixture, are updated in the same change):
--   ok:no-end-user-brew-instruction:<n files>                  exit 0 (unchanged)
--   violation:end-user-brew-instruction:<file>:<line>          exit 1 (was FAIL:...)
--   could-not-run:unreadable:<file>                            exit 2 (was FAIL:unreadable)
--   could-not-run:usage:no-end-user-brew-instruction           exit 2 (no arguments)
-- fs.read is confined to the repository root; a fixture reading scratch copies
-- points the root at its scratch directory with TILLANDSIAS_REPO_ROOT.
--
-- The .sh stripped comments with two seds, kept here as two Lua patterns:
--   s/^[[:space:]]*#.*$//         a comment-only line becomes empty
--   s/[[:space:]]#[^"']*$//        a trailing comment with no quote after it goes

if #arg < 1 then
    log.raw("usage: check-no-end-user-brew-instruction.lua <script>...")
    verdict.emit("could-not-run:usage:no-end-user-brew-instruction", 2)
    return
end

local function executable_part(line)
    if line:match("^%s*#") then
        return ""
    end
    return (line:gsub("%s#[^\"']*$", ""))
end

local n = 0
for i = 1, #arg do
    local f = arg[i]
    local ok, src = pcall(fs.read, f)
    if not ok or src == nil then
        verdict.emit("could-not-run:unreadable:" .. f, 2)
        return
    end
    n = n + 1
    local lineno = 0
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        lineno = lineno + 1
        if executable_part(line):find("brew install jq", 1, true) then
            verdict.emit(("violation:end-user-brew-instruction:%s:%d"):format(f, lineno), 1)
            return
        end
    end
end
verdict.emit(("ok:no-end-user-brew-instruction:%d"):format(n), 0)
