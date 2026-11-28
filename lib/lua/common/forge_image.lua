-- @trace order:2368-efqj
-- common.forge_image — the forge image a fixture that tests ENTRYPOINT SEMANTICS runs:
-- TILLANDSIAS_FORGE_IMAGE, else this VERSION's tag, else the newest local v tag (ci-full
-- bumps VERSION before its build phase, so the exact tag cannot exist yet). nil when there
-- is none. The caller's header declares @env TILLANDSIAS_FORGE_IMAGE.
local M = {}
function M.pick(T)
    local want = env.get("TILLANDSIAS_FORGE_IMAGE")
    if not want or want == "" then want = "localhost/tillandsias-forge:v" .. text.trim(fs.read("VERSION")) end
    if T:run{ "podman", "image", "exists", want }.code == 0 then return want end
    local r = T:run{ "podman", "images", "--format", "{{.Repository}}:{{.Tag}}" }
    local best, key
    for l in (r.stdout or ""):gmatch("[^\n]+") do
        local v = l:match("^localhost/tillandsias%-forge:v([%d.]+)$")
        if v then
            local k = v:gsub("%d+", function(d) return ("%08d"):format(tonumber(d)) end)
            if not key or k > key then best, key = l, k end
        end
    end
    if best then out.line("note: " .. want .. " absent; testing newest available " .. best) end
    return best
end
-- The launcher's hardening, shared by every such run.
M.HARDENED = { "--cap-drop=ALL", "--security-opt=no-new-privileges", "--security-opt=label=disable", "--userns=keep-id" }
function M.run(T, image, args, script, timeout_ms)
    local argv = { "podman", "run", "--rm" }
    for _, a in ipairs(M.HARDENED) do argv[#argv + 1] = a end
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    for _, a in ipairs{ "--entrypoint", "/bin/bash", image, "-euc", script } do argv[#argv + 1] = a end
    argv.timeout_ms = timeout_ms or 120000
    return T:run(argv)
end
return M
