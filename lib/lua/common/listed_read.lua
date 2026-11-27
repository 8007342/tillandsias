-- @trace order:2417-jzhh, order:2416-pscn
--
-- common.listed_read: read EVERY file a checker listed, or block.
--
-- A checker that wraps each read of a listed file in pcall(fs.read) and drops
-- the failure can say ok over files it never read: doris showed this on
-- check-podman-sync-budgets (2416-pscn), where a real violation under an
-- unreadable listing read ok:podman-sync-bounded:0. This helper reads the whole
-- listing once, up front. If any file cannot be read, the checker blocks
-- (exit 2) and names each one. A file that is optional on purpose never
-- belongs in a listing passed here; triage:
-- plan/issues/lua-listed-read-triage-2026-11-26.md.
--
-- Measured on darwin: fs.read returns a non-UTF-8 file (lossy), so a failure
-- here is always a genuinely unreadable file (ENOENT, EACCES), never "binary".
--
--   local listed = require "common.listed_read"
--   local src = listed.read_all("my-check", files)            -- src[path] = body
--   local src = listed.read_all("my-check", items, function(i) return i.path end)

local M = {}

function M.read_all(name, items, path_of)
    local sources, unreadable, seen = {}, {}, {}
    for _, item in ipairs(items or {}) do
        local p = path_of and path_of(item) or item
        if not seen[p] then
            seen[p] = true
            local ok, body = pcall(fs.read, p)
            if ok and type(body) == "string" then sources[p] = body else unreadable[#unreadable + 1] = p end
        end
    end
    if #unreadable > 0 then
        for _, p in ipairs(unreadable) do log.raw("unreadable: " .. p) end
        verdict.emit("blocked:" .. name .. ":unreadable:" .. #unreadable, 2,
            "  why: the listing named files this check could not read, so it cannot say they are clean (2417-jzhh)\n"
            .. "  remedy: make them readable, or remove them from the tree this check lists")
    end
    return sources
end

return M
