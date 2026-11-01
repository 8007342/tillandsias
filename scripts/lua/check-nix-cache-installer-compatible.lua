-- @trace order:1933-ysbq
-- @env TILLANDSIAS_NIX_CACHE_WORKFLOW_DIR
--
-- check-nix-cache-installer-compatible.lua — every workflow that uses
-- nix-community/cache-nix-action must install Nix with an installer that action
-- lists as compatible. DeterminateSystems/nix-installer-action is not on that
-- list; with it the cache save's tar exits 2, so the cache is never written.
--
-- Population: *.yml under TILLANDSIAS_NIX_CACHE_WORKFLOW_DIR (default
-- .github/workflows). A workflow without cache-nix-action is not judged.
--
-- Verdicts:
--   ok:nix-cache-installer:workflows=<n>:judged=<k>                    exit 0
--   violation:nix-cache-installer:<n>                                  exit 1
--   could-not-run:nix-cache-installer:empty-population                 exit 3
--
--   tillandsias-plan script run scripts/lua/check-nix-cache-installer-compatible.lua

local DIR = env.get("TILLANDSIAS_NIX_CACHE_WORKFLOW_DIR") or ""
if DIR == "" then DIR = ".github/workflows" end
local COMPATIBLE = {
    ["nixbuild/nix-quick-install-action"] = true,
    ["cachix/install-nix-action"] = true,
    ["DeterminateSystems/determinate-nix-action"] = true,
}

local files = {}
for _, f in ipairs(fs.list(DIR) or {}) do
    local name = f:match("([^/]+)$") or f
    if name:match("%.yml$") then files[#files + 1] = DIR .. "/" .. name end
end
if #files == 0 then verdict.could_not_run("nix-cache-installer", "empty-population:" .. DIR) end

local bad, judged = 0, 0
for _, wf in ipairs(files) do
    local ok, body = pcall(fs.read, wf)
    if ok and type(body) == "string" then
        local uses, has_cache = {}, false
        for line in (body .. "\n"):gmatch("([^\n]*)\n") do
            if not line:match("^%s*#") then
                local u = line:match("^%s*%-?%s*uses:%s*([^%s#@]+)")
                if u then
                    if u == "nix-community/cache-nix-action" then has_cache = true end
                    local l = u:lower()
                    if l:find("nix", 1, true) and l:find("install", 1, true) then uses[#uses + 1] = u end
                end
            end
        end
        if has_cache then
            judged = judged + 1
            if #uses == 0 then
                log.raw("  fail:nix-cache-installer:" .. wf .. ":no-nix-installer-step"); bad = bad + 1
            end
            for _, u in ipairs(uses) do
                if COMPATIBLE[u] then out.line("  ok:nix-cache-installer:" .. wf .. ":" .. u)
                else
                    log.raw("  fail:nix-cache-installer:" .. wf .. ":" .. u .. " is not a cache-nix-action compatible installer")
                    bad = bad + 1
                end
            end
        end
    end
end
if bad > 0 then
    log.raw("  remedy: install Nix with cachix/install-nix-action (or nix-quick-install-action / determinate-nix-action) in workflows that use cache-nix-action")
    verdict.emit("violation:nix-cache-installer:" .. bad, 1)
end
verdict.emit("ok:nix-cache-installer:workflows=" .. #files .. ":judged=" .. judged, 0)
