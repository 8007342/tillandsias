-- @trace spec:default-image, order:2067-faum
-- @env PATH
-- @env TILLANDSIAS_FORGE_LANG_PATH
-- @env TILLANDSIAS_FORGE_IMAGE_DIR
--
-- check-forge-languages.lua — Lua, Rust and Go are always in the forge
-- (operator ruling 2026-11-09): lua, cargo, rustc and go must resolve to an
-- executable on the forge PATH. They are the tooling languages every forge
-- agent is told to prefer, in that order (forge-agent-guidance.md), so a forge
-- without one of them sends agents back to Python. MEASURED 2026-11-09 in
-- the v56.11.4.1 forge image: all four in /usr/bin (from
-- images/default/Containerfile.base).
--
-- Modes, one verdict line on stdout:
--   (default)        search TILLANDSIAS_FORGE_LANG_PATH (else PATH)
--     ok:forge-languages:lua,cargo,rustc,go              exit 0
--     violation:forge-languages:missing:<cmd>[,<cmd>]    exit 1
--   --containerfile  the forge Containerfile guards its build on the four
--     ok:forge-languages:build-guarded                   exit 0
--     violation:forge-languages:build-unguarded          exit 1
--     blocked:forge-languages:<file>-unreadable          exit 2

local LANGS = { "lua", "cargo", "rustc", "go" }

local mode_containerfile = false
for i = 1, #arg do
    if arg[i] == "--containerfile" then mode_containerfile = true end
end

if mode_containerfile then
    local dir = env.get("TILLANDSIAS_FORGE_IMAGE_DIR") or "images/default"
    local cf = dir .. "/Containerfile"
    if not fs.exists(cf) then verdict.emit("blocked:forge-languages:" .. cf .. "-unreadable", 2) end
    local text = fs.read(cf)
    -- The guard is one RUN naming all four commands, with "2067-faum" on it.
    local guarded = false
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^RUN%s") and line:find("2067-faum", 1, true)
            and line:find("lua cargo rustc go", 1, true) then
            guarded = true
        end
    end
    if not guarded then verdict.emit("violation:forge-languages:build-unguarded", 1) end
    verdict.emit("ok:forge-languages:build-guarded", 0)
end

local search = env.get("TILLANDSIAS_FORGE_LANG_PATH") or env.get("PATH") or ""
local dirs = {}
for d in (search .. ":"):gmatch("([^:]*):") do
    if d ~= "" then dirs[#dirs + 1] = d end
end

local function found(cmd)
    for _, d in ipairs(dirs) do
        -- test -x, not fs.exists: the sandboxed fs refuses paths outside the
        -- repository, and /usr/bin is exactly where a forge keeps these.
        local r = proc.run({ argv = { "test", "-f", d .. "/" .. cmd, "-a", "-x", d .. "/" .. cmd }, timeout_ms = 5000 })
        if r.code == 0 then return true end
    end
    return false
end

local missing = {}
for _, c in ipairs(LANGS) do
    if not found(c) then missing[#missing + 1] = c end
end
if #missing > 0 then
    verdict.emit("violation:forge-languages:missing:" .. table.concat(missing, ","), 1)
end
verdict.emit("ok:forge-languages:" .. table.concat(LANGS, ","), 0)
