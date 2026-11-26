-- @trace order:1264-s4id, order:2393-j27x, spec:default-image
-- @class observing
--
-- push-capability.lua — the bodies of images/default/lib-push-capability.sh, run by
-- `tillandsias-plan script run --helper` (openspec change forge-lua-helpers D3.6).
-- One git read (or one discipline check) through proc.run replaces the
-- sed | awk | sort | tail | cut and head | cut | sed pipelines. The shell keeps the
-- vocabulary-to-sentence mapping and every check that needs no process.
--
--   repo <dir>                 the mirror's newest upstream-auth verdict
--     two lines: <state> <sub>, each `-` when absent, or `unreachable` alone when
--     ls-remote fails. <state> is the first path segment under
--     refs/tillandsias/upstream-auth/, <sub> the second; the newest is the largest
--     trailing epoch (a non-number counts as 0), ties broken by the whole line,
--     exactly as `sort -n | tail -n 1` broke them.
--   branch <dir> <branch> <plan>   the project's discipline on that branch
--     three lines: the first line of `discipline check-ref`, the third :-field of
--     it (`-` when absent), and the first `remedy: ` line's text (`-` when none).
--
-- Environment (2029-39bt): git and the plan binary run from the base environment;
-- the checkout is an argument (-C / --root), never GIT_DIR.

local mode, dir = arg[1] or "", arg[2] or ""

local function lines(s)
    local t = {}
    for l in ((s or ""):gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
    return t
end

if mode == "repo" then
    local r = proc.run{ argv = { "git", "-C", dir, "ls-remote", "origin", "refs/tillandsias/upstream-auth/*" }, timeout_ms = 30000 }
    if r.status ~= "exited" or r.code ~= 0 then
        out.line("unreachable")
        return
    end
    local best, best_key, best_line
    for _, l in ipairs(lines(r.stdout)) do
        local rest = l:match("^%x*%s+refs/tillandsias/upstream%-auth/(.*)$")
        if rest and rest:find("/", 1, true) then
            local epoch = tonumber(rest:match("([^/]*)$")) or 0
            local key = rest:match("([^/]*)$") .. "\t" .. rest
            if not best or epoch > best or (epoch == best and key > best_key) then
                best, best_key, best_line = epoch, key, rest
            end
        end
    end
    if not best_line then
        out.line("-"); out.line("-")
        return
    end
    out.line(best_line:match("^([^/]*)") or "-")
    out.line(best_line:match("^[^/]*/([^/]*)") or "-")
    return
end

if mode == "branch" then
    local branch, plan = arg[3] or "", arg[4] or ""
    local r = proc.run{ argv = { plan, "discipline", "check-ref", "refs/heads/" .. branch, "--root", dir }, timeout_ms = 30000 }
    local all = lines((r.stdout or "") .. (r.stderr or ""))
    local first, remedy = all[1] or "", "-"
    for _, l in ipairs(all) do
        local t = l:match("^remedy: (.*)$")
        if t then remedy = t; break end
    end
    out.line(first ~= "" and first or "-")
    out.line(first:match("^[^:]*:[^:]*:([^:]*)") or "-")
    out.line(remedy)
    return
end

error("push-capability.lua: unknown mode `" .. mode .. "` (repo | branch)")
