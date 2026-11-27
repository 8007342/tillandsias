-- @trace order:2418-ct85
--
-- common/argv_batch.lua — run one command over a long item list in argv batches that fit every
-- host's command line. Windows caps a whole command line at 32 767 UTF-16 units (CreateProcess):
-- past it the spawn fails with os error 206 and the command never runs, so a caller that put a
-- whole file list in one argv read "nothing parsed" (check-all-fragments-intact, 7 820 fragments:
-- blocked ... 7820 damaged) or "every file unaccounted" (2418-kvdz). Linux allows far more, but
-- the batched result is the same there, so callers batch everywhere and no host forks.
--
--   local batch = require "common.argv_batch"
--   local r = batch.run({ "tool", "validate-yaml" }, files, { cwd = root })
--   -- r.stdout, r.stderr: every batch's output, in order, concatenated
--   -- r.code: the worst exit over batches, or nil when any batch did not exit (spawn failed,
--   --         timed out, signalled); r.status: "exited" only when every batch exited
--   -- r.batches: how many runs it took
--
-- opts: cwd, env, env_unset, timeout_ms (per batch), budget (characters per command line,
-- default 24 000: well under 32 767 after quoting and the base argv), max_items (optional cap).
-- An item longer than the budget on its own still runs, alone in its batch.

local M = {}

M.BUDGET = 24000

local function cost(s) return #s + 3 end  -- the item, a separating space, and room for quotes

function M.run(base, items, opts)
    opts = opts or {}
    local budget, max_items = opts.budget or M.BUDGET, opts.max_items
    local base_cost = 0
    for _, a in ipairs(base) do base_cost = base_cost + cost(a) end
    local out, err = {}, {}
    local code, status, batches = 0, "exited", 0
    local i, n = 1, #items
    if n == 0 then return { stdout = "", stderr = "", code = 0, status = "exited", batches = 0 } end
    while i <= n do
        local argv, used, k = {}, base_cost, 0
        for _, a in ipairs(base) do argv[#argv + 1] = a end
        while i <= n do
            local c = cost(items[i])
            if k > 0 and (used + c > budget or (max_items and k >= max_items)) then break end
            argv[#argv + 1] = items[i]; used = used + c; k = k + 1; i = i + 1
        end
        local r = proc.run({ argv = argv, cwd = opts.cwd, env = opts.env, env_unset = opts.env_unset,
            timeout_ms = opts.timeout_ms })
        batches = batches + 1
        out[#out + 1] = r.stdout or ""; err[#err + 1] = r.stderr or ""
        if r.status ~= "exited" or r.code == nil then
            code, status = nil, r.status or "spawn_failed"
        elseif code ~= nil and r.code > code then
            code = r.code
        end
    end
    return { stdout = table.concat(out), stderr = table.concat(err), code = code, status = status, batches = batches }
end

return M
