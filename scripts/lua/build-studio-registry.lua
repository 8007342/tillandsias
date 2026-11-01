-- @trace order:1860-auhm, spec:web-studio-lane
--
-- build-studio-registry.lua — evaluate images/studio/registry.lua (pure data,
-- empty environment) and write it as crates/tillandsias-headless/data/studios.json,
-- which the launcher embeds. The output is canonical (sorted keys, two-space
-- indent, this file's own encoder), so a re-run is byte-identical:
--   tillandsias-plan script run scripts/lua/build-studio-registry.lua             (write)
--   tillandsias-plan script run scripts/lua/build-studio-registry.lua -- --check  (verify)
-- Verdicts: ok:studio-registry:written:<n> | ok:studio-registry:fresh:<n> |
--           violation:studio-registry:stale (exit 1) | refused:studio-registry:<why> (exit 1)

local SRC = "images/studio/registry.lua"
local OUT = "crates/tillandsias-headless/data/studios.json"
local check = false
for _, a in ipairs(arg or {}) do
    if a == "--check" then check = true end
end

local text = fs.read(SRC)
if not text then verdict.emit("refused:studio-registry:unreadable:" .. SRC, 1) end
local chunk, err = load(text, "=" .. SRC, "t", {})
if not chunk then verdict.emit("refused:studio-registry:parse:" .. tostring(err), 1) end
local okc, reg = pcall(chunk)
if not okc or type(reg) ~= "table" then verdict.emit("refused:studio-registry:eval:" .. tostring(reg), 1) end

-- Shape checks: a field the launcher reads must be present and typed.
local REQUIRED = { id = "string", name = "string", brief = "string", license = "string",
                   frameworks = "table", entry = "table", port = "number",
                   save_adapter = "string", write_allowlist = "table",
                   status = "string", packet = "string" }
local seen = {}
for i, s in ipairs(reg.studios or {}) do
    for k, t in pairs(REQUIRED) do
        if type(s[k]) ~= t then
            verdict.emit("refused:studio-registry:studio-" .. i .. ":" .. k .. "-not-" .. t, 1)
        end
    end
    if seen[s.id] then verdict.emit("refused:studio-registry:duplicate:" .. s.id, 1) end
    seen[s.id] = true
    if not s.id:match("^[a-z][a-z0-9-]*$") then verdict.emit("refused:studio-registry:bad-id:" .. s.id, 1) end
    if s.save_adapter ~= "endpoint" and s.save_adapter ~= "own-writer" then
        verdict.emit("refused:studio-registry:save-adapter:" .. s.id, 1)
    end
    if s.status ~= "planned" and s.status ~= "ready" then
        verdict.emit("refused:studio-registry:status:" .. s.id, 1)
    end
end
if seen.silex then verdict.emit("refused:studio-registry:silex-is-not-offered", 1) end
if #(reg.studios or {}) == 0 then verdict.emit("refused:studio-registry:empty", 1) end

local function is_array(t)
    if table.is_empty(t) then return true end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n == #t
end

local function enc(v, ind)
    local t = type(v)
    if t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c)
            local m = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\t'] = '\\t' }
            return m[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    elseif t == "number" then
        return (math.type and math.type(v) == "integer") and tostring(v) or string.format("%d", v)
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        local pad, inner = string.rep("  ", ind), string.rep("  ", ind + 1)
        if is_array(v) then
            if #v == 0 then return "[]" end
            local parts = {}
            for _, x in ipairs(v) do parts[#parts + 1] = inner .. enc(x, ind + 1) end
            return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = inner .. enc(k, ind + 1) .. ": " .. enc(v[k], ind + 1) end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
    end
    verdict.emit("refused:studio-registry:unencodable:" .. t, 1)
end

local body = enc(reg, 0) .. "\n"
local n = #reg.studios
if check then
    if fs.read(OUT) == body then verdict.emit("ok:studio-registry:fresh:" .. n, 0) end
    out.line("  why: " .. OUT .. " does not match " .. SRC)
    out.line("  remedy: tillandsias-plan script run scripts/lua/build-studio-registry.lua")
    verdict.emit("violation:studio-registry:stale", 1)
end
fs.mkdir("crates/tillandsias-headless/data")
fs.write(OUT, body)
verdict.emit("ok:studio-registry:written:" .. n, 0)
