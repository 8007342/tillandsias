-- @env PATH HOME
-- @trace spec:forge-environment-discoverability, spec:forge-offline, order:801-a2by, order:2391-d389
--
-- check-spec-index-resolution-agreement.lua — the spec-index PRODUCER and its two READERS must resolve the same
-- directory (order 801-a2by).
--
-- Order 552 found the embedding step existed on no host, only as prose inside forge-plan.sh's refusal, so
-- `spec_answer` refused everywhere for weeks while every validator stayed green; 789-nc2s produced the same silence
-- from a stale FORGE_SPEC_INDEX_DIR. 801-a2by made the location a precedence chain (exact dir > explicit root >
-- podman named volume > XDG cache) carried by three files in two runtimes, which cannot share a file at runtime:
--   scripts/spec-index-ensure.sh                     the producer
--   images/default/config-overlay/mcp/forge-plan.sh  spec_answer
--   images/default/lib-expert-capability.sh          the capability line
-- So the block is duplicated deliberately and its agreement GUARDED.
--
-- THE PROPERTY, NOT THE TEXT. Identical bytes first; then each extracted block is EXECUTED under several
-- environments (with nothing inherited: a stale exported variable is 789-nc2s) and the resolved (root, serving)
-- pairs must agree; a vacuous extraction cannot print two paths. Last, the producer's own --where must follow the
-- block it carries, not a second resolution beside it. The block is shell, so it is run by the POSIX shell.
-- Ported from the .sh of the same name; its --selftest is test-spec-index-resolution-agreement.lua.
--
-- Usage: tillandsias-plan script run scripts/lua/check-spec-index-resolution-agreement.lua [-- --root <checkout>]
-- Verdict: ok:spec-index-resolution-agreement:carriers=<n>-scenarios=<m> | violation:spec-index-resolution:<why>

local args = arg or {}
local ROOT = (args[1] == "--root" and args[2]) or text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }).stdout or "")
local ep = text.trim(proc.run({ argv = { "git", "--exec-path" }, timeout_ms = 10000 }).stdout or "")
local SH = ep:find("^%a:/.*/libexec/git%-core$") and (ep:gsub("/[^/]+/libexec/git%-core$", "/bin/bash.exe")) or "sh"
local function fail(why) verdict.emit("violation:spec-index-resolution:" .. why, 1) end

local CARRIERS = { "scripts/spec-index-ensure.sh", "images/default/config-overlay/mcp/forge-plan.sh", "images/default/lib-expert-capability.sh" }
local BEGIN, END = "# >>> BEGIN spec-index resolution (801-a2by)", "# <<< END spec-index resolution (801-a2by)"

-- The block, markers included, or "" (a file without the markers must never extract to something).
local function extract(body)
    local out, on = {}, false
    for l in ((body or ""):gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
        if not on and l:sub(1, #BEGIN) == BEGIN then on = true end
        if on then out[#out + 1] = l end
        if on and l:sub(1, #END) == END then break end
    end
    return #out > 0 and (table.concat(out, "\n") .. "\n") or ""
end
local function slurp(p)
    local r = proc.run({ argv = { SH, "-s", "--", p }, stdin = '[ -f "$1" ] && cat -- "$1"\n', timeout_ms = 30000 })
    return r.code == 0 and r.stdout or nil
end
-- Run a block in a shell that inherits nothing but HOME, PATH and the scenario; print "root|serving|".
local function resolve(block, vars)
    local e = { HOME = env.get("HOME") or "/nonexistent", PATH = env.get("PATH") }
    for k, v in pairs(vars) do e[k] = v end
    local r = proc.run({ argv = { SH, "-s" }, env = e, env_unset = { "TILLANDSIAS_*", "FORGE_*", "XDG_*", "CARGO_TARGET_DIR" },
        timeout_ms = 30000, stdin = block .. "\n_tillandsias_spec_index_paths | tr '\\n' '|'\n" })
    return (r.stdout or ""):gsub("\r", "")
end

local blocks, n = {}, 0
for _, rel in ipairs(CARRIERS) do
    local body = slurp(ROOT .. "/" .. rel)
    if not body then fail("carrier-missing:" .. rel) end
    n = n + 1
    local b = extract(body)
    if b == "" then fail("no-resolution-block:" .. rel .. " (markers absent — a carrier that stopped carrying the block would otherwise 'agree' with everything)") end
    if not b:find("_tillandsias_spec_index_paths()", 1, true) then fail("block-has-no-resolver:" .. rel) end
    blocks[n] = b
end
for i, rel in ipairs(CARRIERS) do
    if blocks[i] ~= blocks[1] then
        log.raw("The spec-index resolution block drifted in " .. rel .. ".")
        fail("block-drift:" .. rel)
    end
end

-- Each scenario exercises a different rung, so a chain reordered in one carrier is caught even if another rung
-- still matches. NO_PODMAN keeps it deterministic with or without podman; the producer's --where covers that rung.
local SCENARIOS = {
    { "exact-dir", { FORGE_SPEC_INDEX_DIR = "/tmp/exact", FORGE_SPEC_INDEX_ROOT = "", TILLANDSIAS_SPEC_INDEX_NO_PODMAN = "1" } },
    { "explicit-root", { FORGE_SPEC_INDEX_ROOT = "/tmp/root", TILLANDSIAS_SPEC_INDEX_NO_PODMAN = "1" } },
    { "xdg-fallback", { XDG_CACHE_HOME = "/tmp/xdg", TILLANDSIAS_SPEC_INDEX_NO_PODMAN = "1" } },
}
local checked = 0
for _, sc in ipairs(SCENARIOS) do
    local expect
    for i, rel in ipairs(CARRIERS) do
        local got = resolve(blocks[i], sc[2])
        if got == "" then fail("resolver-produced-nothing:" .. rel .. ":" .. sc[1]) end
        if not got:find("|.*|$") then fail("resolver-shape:" .. rel .. ":" .. sc[1] .. ":" .. got) end
        if not expect then expect = got elseif got ~= expect then
            fail("resolved-differently:" .. sc[1] .. ":" .. rel .. " got='" .. got .. "' want='" .. expect .. "'")
        end
    end
    checked = checked + 1
end

-- The producer must CALL the block it carries, not carry it decoratively beside a second resolution.
local where = proc.run({ argv = { SH, ROOT .. "/scripts/spec-index-ensure.sh", "--where" }, timeout_ms = 60000,
    env = { PATH = env.get("PATH"), HOME = env.get("HOME"), FORGE_SPEC_INDEX_ROOT = "/tmp/where-probe", TILLANDSIAS_SPEC_INDEX_NO_PODMAN = "1" },
    env_unset = { "TILLANDSIAS_*", "FORGE_*" } })
local where_root = ((where.stdout or ""):gsub("\r", "")):match("spec%-index:root=([^\n]*)")
if where_root ~= "/tmp/where-probe" then
    fail("producer-ignores-its-own-block:--where reported root='" .. (where_root or "<empty>") .. "' for FORGE_SPEC_INDEX_ROOT=/tmp/where-probe")
end
checked = checked + 1
verdict.emit("ok:spec-index-resolution-agreement:carriers=" .. n .. "-scenarios=" .. checked, 0)
