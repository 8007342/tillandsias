-- @trace order:2267-6ss8, order:2266-4w3c, order:1072-b7eq
-- @env TILLANDSIAS_GATE_STEP_INLINE_ROOT
--
-- check-gate-step-not-also-inline.lua — a fixture runs ONCE per gate: refuse
-- any script that a scripts/gate-steps.d/*.step names (STEP_SCRIPT or STEP_LUA)
-- and that an inline build.sh block also runs (`_run bash "…/<script>"` or
-- `_run_lua_decider "<script>"`).
--
-- WHY. Step 286 (1461-5rm6) bound scripts/test-land-queue.sh on 2026-09-28 and
-- its inline block was never removed, so every gate ran it twice (48 s each)
-- until 2266-4w3c. test-gate-step-append-no-conflict.sh refuses two .step
-- files naming one script, but never compares a .step with build.sh, so the
-- duplicate passed every guard for eight weeks.
--
-- Root: the checkout, or TILLANDSIAS_GATE_STEP_INLINE_ROOT (the fixture's
-- scratch tree).
-- Verdict: ok:gate-step-not-also-inline:<steps>:<inline>
--        | violation:gate-step-not-also-inline:<n> (one line per duplicate)

local root = env.get("TILLANDSIAS_GATE_STEP_INLINE_ROOT") or ""
local function path(p) return root == "" and p or root .. "/" .. p end

local okb, build = pcall(fs.read, path("build.sh"))
if not okb or not build then verdict.could_not_run("gate-step-not-also-inline", "cannot read build.sh") end

-- inline[script] = first build.sh line that runs it
local inline, n_inline, ln = {}, 0, 0
for line in (build .. "\n"):gmatch("(.-)\n") do
    ln = ln + 1
    local code = line:gsub("^%s+", "")
    if code:sub(1, 1) ~= "#" then
        local s = code:match('_run_lua_decider%s+"([^"]+)"')
            or code:match('_run%s+bash%s+"%$SCRIPT_DIR/([^"]+)"')
            or code:match('_run%s+bash%s+"(scripts/[^"]+)"')
        if s and not inline[s] then inline[s] = ln; n_inline = n_inline + 1 end
    end
end

local okl, names = pcall(fs.list, path("scripts/gate-steps.d"))
if not okl or not names then verdict.could_not_run("gate-step-not-also-inline", "cannot list scripts/gate-steps.d") end
table.sort(names)
local bad, n_steps = 0, 0
for _, f in ipairs(names) do
    local name = f:match("([^/]+)$")
    if name:match("%.step$") then
        n_steps = n_steps + 1
        local body = fs.read(path("scripts/gate-steps.d/" .. name)) or ""
        for _, key in ipairs({ "STEP_SCRIPT", "STEP_LUA" }) do
            local s = body:match("\n" .. key .. '="([^"]+)"') or body:match("^" .. key .. '="([^"]+)"')
            if s and inline[s] then
                bad = bad + 1
                out.line("violation:gate-step-not-also-inline:" .. s .. ": gate step " .. name
                    .. " runs it AND build.sh:" .. inline[s] .. " runs it inline, so every gate runs it twice;"
                    .. " delete the inline block (the step is the gate's copy) (2267-6ss8)")
            end
        end
    end
end
if bad > 0 then verdict.emit("violation:gate-step-not-also-inline:" .. bad, 1) end
verdict.emit("ok:gate-step-not-also-inline:" .. n_steps .. ":" .. n_inline, 0)
