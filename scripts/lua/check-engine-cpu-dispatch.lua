-- @trace order:861-n7f5, order:392, order:2199-luab, spec:inference-container
-- @env PATH HOME HOSTNAME TILLANDSIAS_WORKSTATION TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN ENGINE_DISPATCH_HOST_FLAGS ENGINE_DISPATCH_SYSINFO_FILE ENGINE_DISPATCH_CHECKED_FEATURES
--
-- check-engine-cpu-dispatch.lua: does this engine BUILD dispatch the vector
-- features this host actually has? (Port of check-engine-cpu-dispatch.sh,
-- order 2199-luab. Verdict lines and exit codes are byte-identical; the
-- unavailable: word is admitted by verdict.emit's LEGACY_VERDICT_WORDS, 2193-vtbl.)
--
-- WHY THIS EXISTS. Measured on esmeraldinha 2026-08-23: Fedora 44's packaged
-- `llama-cpp` (b6153-3.fc44) is 12.8x slower on prefill and 4.0x slower on
-- decode than ollama on the IDENTICAL GGUF blob and the same four cores. Both
-- are llama.cpp: the BUILD is the variable. Fedora's reports
-- `CPU : LLAMAFILE = 1 | REPACK = 1` and no AVX, AVX2, FMA or AVX_VNNI on a host
-- whose capability row lists all four. This is the CPU lane's version of the
-- order-392 rule (a tier in name only is worse than no tier).
--
-- WHAT IT DOES NOT DO. It does not benchmark, load a model or judge speed. It
-- answers which vector features the build will use, and refuses a candidate
-- whose build ignores features the host advertises.
--
-- THE HOST'S HALF COMES FROM THE CAPABILITY ROW, NEVER A SECOND PROBE:
-- `tillandsias-plan capability-matrix --cpu-flags <host>`. ENGINE_DISPATCH_HOST_FLAGS
-- overrides it, for fixtures and for a host whose row is not published yet.
--
-- Grammar (exactly one line on stdout):
--   ^(ok:engine-cpu-dispatch:[a-z0-9_,-]+|refused:engine-cpu-dispatch-baseline:[a-z0-9_,-]+|unavailable:[a-z0-9-]+)$
-- Exit: 0 every advertised checked feature dispatched; 1 refused (a baseline
-- build on a vector host); 2 could not determine (never guess).
--
-- Usage:
--   tillandsias-plan script run scripts/lua/check-engine-cpu-dispatch.lua -- /usr/bin/llama-server
--
-- Fixture seam: ENGINE_DISPATCH_SYSINFO_FILE names a file whose contents stand
-- in for the engine's output. (The .sh took ENGINE_DISPATCH_SYSINFO_CMD, a
-- shell string it eval'd; the Lua door runs no shells, so the seam is a file.)

local function emit(line, code) verdict.emit(line, code) end
local function nonempty(s) return s ~= nil and s ~= "" end

local CHECKED = env.get("ENGINE_DISPATCH_CHECKED_FEATURES")
if not nonempty(CHECKED) then CHECKED = "avx avx2 fma avx_vnni" end

local engine = arg[1]
if not nonempty(engine) then
    log.raw("[check-engine-cpu-dispatch] usage: check-engine-cpu-dispatch.lua <engine-binary>")
    emit("unavailable:no-engine-given", 2)
end

-- a set of lower-case flags from text split on commas, spaces or newlines
local function flag_set(s)
    local set, order = {}, {}
    for f in string.gmatch(string.lower(s), "[^,%s]+") do
        if not set[f] then set[f] = true; order[#order + 1] = f end
    end
    return set, order
end

-- ---------------------------------------------------------------- host flags
local host_set, host_order
local host_source = "capability-row"
local override = env.get("ENGINE_DISPATCH_HOST_FLAGS")
if nonempty(override) then
    host_set, host_order = flag_set(override)
    host_source = "override"
else
    local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
    if not nonempty(PLAN) then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
    if not nonempty(PLAN) then PLAN = "tillandsias-plan" end
    -- the workstation, as agent-identity.sh resolves it: TILLANDSIAS_WORKSTATION,
    -- else the host name, short and lower-cased
    local host = env.get("TILLANDSIAS_WORKSTATION")
    if not nonempty(host) then host = env.get("HOSTNAME") end
    if not nonempty(host) then
        local u = proc.run({ argv = { "uname", "-n" }, timeout_ms = 10000 })
        host = text.trim(u.stdout or "")
    end
    host = string.lower((host:gsub("%..*$", "")))
    if not nonempty(host) then emit("unavailable:host-unresolvable", 2) end
    local r = proc.run({ argv = { PLAN, "capability-matrix", "--cpu-flags", host }, timeout_ms = 60000 })
    if r.status ~= "exited" or r.code ~= 0 then emit("unavailable:capability-matrix-failed", 2) end
    local row = text.lines(r.stdout or "")[1]
    -- absent from the matrix prints nothing: a DIFFERENT fact from a row with no flags
    if not nonempty(row) then emit("unavailable:no-capability-row", 2) end
    local csv = row:match("^[^\t]*\t([^\t]*)") or ""
    if csv == "none" then emit("unavailable:capability-row-has-no-cpu-flags", 2) end
    host_set, host_order = flag_set(csv)
end

-- ------------------------------------------------------------- engine sysinfo
-- llama.cpp prints its dispatch table at startup, e.g.
--   system_info: n_threads = 4 | AVX = 1 | AVX2 = 1 | FMA = 1 | AVX_VNNI = 0 | ...
local sysinfo
local seam = env.get("ENGINE_DISPATCH_SYSINFO_FILE")
if nonempty(seam) then
    local c = proc.run({ argv = { "cat", seam }, timeout_ms = 10000 })
    sysinfo = c.stdout or ""
else
    local x = proc.run({ argv = { "test", "-x", engine }, timeout_ms = 10000 })
    if x.status ~= "exited" or x.code ~= 0 then emit("unavailable:engine-not-executable", 2) end
    local v = proc.run({ argv = { engine, "--version" }, timeout_ms = 30000 })
    sysinfo = (v.stdout or "") .. (v.stderr or "")
    -- one retry with --help, which carries the same table on other builds
    if not (sysinfo:lower():find("avx", 1, true) or sysinfo:find("LLAMAFILE", 1, true) or sysinfo:find("REPACK", 1, true)) then
        local h = proc.run({ argv = { engine, "--help" }, timeout_ms = 30000 })
        sysinfo = (h.stdout or "") .. (h.stderr or "")
    end
end
if not nonempty(sysinfo) then emit("unavailable:engine-emitted-nothing", 2) end

-- the dispatch table must be present: a banner with no table is not a pass
if not (sysinfo:find("[Aa][Vv][Xx] = ") or sysinfo:find("LLAMAFILE = ", 1, true) or sysinfo:find("REPACK = ", 1, true)) then
    emit("unavailable:no-dispatch-table", 2)
end

-- ------------------------------------------------------------------- compare
-- `FEATURE = 1` means dispatched; `= 0` or absent means not. The feature name
-- must not be the tail of a longer one (AVX inside AVX_VNNI / AVX2 is not AVX).
local function build_has(upper)
    local padded = " " .. sysinfo .. " "
    local start = 1
    while true do
        local i, j = padded:find(upper .. " = 1", start, true)
        if not i then return false end
        local before = padded:sub(i - 1, i - 1)
        local after = padded:sub(j + 1, j + 1)
        if not before:match("[A-Z_]") and not after:match("%d") then return true end
        start = i + 1
    end
end

local dispatched, missing = {}, {}
for f in string.gmatch(CHECKED, "%S+") do
    local has = build_has(string.upper(f))
    if has then dispatched[#dispatched + 1] = f end
    if host_set[f] and not has then missing[#missing + 1] = f end
end

if #missing > 0 then
    local d = #dispatched > 0 and table.concat(dispatched, ",") or "none"
    log.raw("[check-engine-cpu-dispatch] REFUSED: this build ignores vector features this host has.")
    log.raw("  host advertises (" .. host_source .. "): " .. table.concat(host_order, ","))
    log.raw("  build dispatches:               " .. d)
    log.raw("  ignored by the build:           " .. table.concat(missing, ","))
    log.raw("  A baseline build on a vector host is a MISCONFIGURATION, not a candidate.")
    log.raw("  It benchmarks as a regression nobody can explain (861-n7f5: 12.8x prefill).")
    emit("refused:engine-cpu-dispatch-baseline:" .. table.concat(missing, ","), 1)
end

emit("ok:engine-cpu-dispatch:" .. (#dispatched > 0 and table.concat(dispatched, ",") or "none"), 0)
