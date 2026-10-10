-- @trace order:1406-9ctt, order:756-rfdr, order:1582-c32p, spec:binary-signing
--
-- check-release-uploads-gated.lua — every `gh release upload <tag> <dir>/*` in
-- a release workflow must be preceded, IN THE SAME JOB, by
-- `check-release-asset-integrity.sh <dir>` over that same directory. A
-- whole-file count of the check (the old pin, "exactly 2") went red when a job
-- gained a correct check, and stayed green while macos-release uploaded twice
-- with none: it counted the words, not which upload they gated.
--
-- PORTED from scripts/check-release-uploads-gated.sh (an awk program), rule
-- for rule and verdict for verdict, as 1582-c32p's carried shell-to-lua item.
--
-- GRAMMAR (exactly one line on stdout)
--   ok:release-uploads-gated:<n> uploads in <j> jobs          exit 0
--   refused:release-uploads-gated:ungated=<job>:<dir>[,...]   exit 1
--   could-not-run:release-uploads-gated:<reason>              exit 3
--
-- Usage: tillandsias-plan script run scripts/lua/check-release-uploads-gated.lua [-- <workflow.yml>]
local wf = arg[1] or ".github/workflows/release.yml"
local ok, src = pcall(fs.read, wf)
if not ok or not src then verdict.emit("could-not-run:release-uploads-gated:no-file:" .. wf, 3) end

local function fields(l) local t = {}; for w in l:gmatch("%S+") do t[#t + 1] = w end; return t end

local job, cwd, cont = "", "", false
local gated, jobs, njobs, n, bad = {}, {}, 0, 0, {}
for _, l in ipairs(text.lines(src)) do
    -- Comments cannot publish anything (and name `gh release upload` in prose).
    if l:find("^%s*#") then goto continue end
    -- A job header: two-space indent, a key, a colon, nothing after.
    do
        local key = l:match("^  ([%w_%-]+):%s*$")
        if key then job = key; gated = {}; cwd = ""; goto continue end
    end
    do
        local f = fields(l)
        -- Each step runs in a fresh shell at the workspace root.
        if l:find("^%s*%- name:") then cwd = ""; cont = false end
        if l:find("^%s*cd%s+%S+%s*$") then cwd = (f[2] == ".." and "" or f[2]) end
        if l:find("check%-release%-asset%-integrity%.sh%s+%S+") then
            for i = 1, #f - 1 do
                if f[i]:find("check%-release%-asset%-integrity%.sh$") then
                    local g = f[i + 1]; if g == "." then g = cwd end; gated[g] = true
                end
            end
        end
        -- A publishing command, and the backslash-continued lines under it.
        if l:find("gh release upload") or l:find("gh release create") then cont = true end
        if cont then
            for i = 1, #f do
                if f[i]:find("/%*$") then
                    local d = f[i]:gsub("/%*$", "")
                    n = n + 1
                    if not jobs[job] then jobs[job] = true; njobs = njobs + 1 end
                    if not gated[d] then bad[#bad + 1] = job .. ":" .. d end
                end
            end
            cont = (f[#f] == "\\")
        end
    end
    ::continue::
end

if n == 0 then verdict.emit("could-not-run:release-uploads-gated:no-uploads-found", 3) end
if #bad > 0 then verdict.emit("refused:release-uploads-gated:ungated=" .. table.concat(bad, ","), 1) end
verdict.emit(("ok:release-uploads-gated:%d uploads in %d jobs"):format(n, njobs), 0)
