-- @trace order:1324-emdf
--
-- test-smoke-gate-precedes-destruction.lua — the smoke runbook reads its
-- authorisation BEFORE the first step that destroys anything. Since 1286-4437
-- every installer runs `--reset-state` itself, so §1 destroys. A gate at §2
-- was bypassed by the order of the steps (yolanda-windows, v56.9.20.1,
-- 2026-09-21).
--
-- The check reads the runbook as text:
--   * the AUTHORISATION GATE step, with its TILLANDSIAS_DESTRUCTIVE_RESET_OK=0
--     stop, appears before the `## 1 —` heading;
--   * the `## 1 —` heading carries DESTRUCTIVE;
--   * §2 names what it still destroys on Linux, macOS and Windows, and
--     carries no "=0, stop here" gate of its own (the old position);
--   * each installer still calls --reset-state. Without that the premise
--     is gone and the row needs a fresh look, so the fixture refuses.
-- ARM 1 runs the check over the live runbook. ARMS 2-5 are mutants of it, one
-- per refusal shape, and each must be refused.
--
-- Usage: tillandsias-plan script run scripts/lua/test-smoke-gate-precedes-destruction.lua

local RUNBOOK = "skills/smoke-curl-install-and-test-e2e/SKILL.md"
local INSTALLERS = { "scripts/install.sh", "scripts/install-macos.sh", "scripts/install-windows.ps1" }

local function plain(s, needle, init) return s:find(needle, init or 1, true) end

-- Returns a list of reasons; empty means the runbook is sound.
local function check(body)
    local why = {}
    local s1 = body:find("\n## 1 — ", 1, true)
    local s2 = body:find("\n## 2 — ", 1, true)
    local s3 = body:find("\n## 3 — ", 1, true)
    if not (s1 and s2 and s3) then return { "missing a §1, §2 or §3 heading" } end
    local gate = plain(body, "AUTHORISATION GATE: HERE, BEFORE §1")
    if not gate then why[#why + 1] = "no AUTHORISATION GATE step"
    elseif gate > s1 then why[#why + 1] = "the AUTHORISATION GATE step sits after the §1 heading" end
    local stop = plain(body, "`TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`, **stop\n     now**, before §1")
    if not stop or stop > s1 then why[#why + 1] = "the =0 stop is not before §1" end
    local h1 = body:sub(s1 + 1, (body:find("\n", s1 + 1, true) or #body) - 1)
    if not plain(h1, "DESTRUCTIVE") then why[#why + 1] = "the §1 heading carries no DESTRUCTIVE banner" end
    local sec2 = body:sub(s2, s3)
    for _, p in ipairs({ "- **Linux**:", "- **macOS**:", "- **Windows**:" }) do
        if not plain(sec2, p) then why[#why + 1] = "§2 does not say what it still destroys on " .. p:match("%*%*(%w+)") end
    end
    if plain(sec2, "stop here, write a plan blocker") then
        why[#why + 1] = "§2 still carries its own =0 gate (the pre-1324-emdf position)"
    end
    return why
end

local fails, arms = 0, 0
local function arm(label, ok, detail)
    arms = arms + 1
    if ok then print("PASS arm " .. arms .. ": " .. label)
    else fails = fails + 1; print("FAIL arm " .. arms .. ": " .. label .. " — " .. (detail or "")) end
end

local body = fs.read(RUNBOOK)
if not body then verdict.could_not_run("smoke-gate-precedes-destruction", "cannot read " .. RUNBOOK) end

for _, f in ipairs(INSTALLERS) do
    local src = fs.read(f) or ""
    if not src:find("%-%-reset%-state </dev/null") and not src:find("%-%-reset%-state < NUL") then
        verdict.refused("smoke-gate-precedes-destruction", "premise-gone:" .. f .. ":no-reset-state-call")
    end
end

-- ARM 1: the live runbook.
local live = check(body)
arm("the live runbook gates before §1", #live == 0, table.concat(live, "; "))

local function swap(s, old, new)
    local i = s:find(old, 1, true)
    if not i then return nil end
    return s:sub(1, i - 1) .. new .. s:sub(i + #old)
end
local function refused(label, mutant)
    if not mutant then arm(label, false, "mutant could not be built (runbook text moved)"); return end
    local r = check(mutant)
    arm(label, #r > 0, "mutant was accepted")
end

-- ARM 2: the gate moved to the top of §2 (the defect).
local i, j = body:find("6. **AUTHORISATION GATE", 1, true), body:find("\n---\n\n## 1 — ", 1, true)
local gate_text = (i and j) and body:sub(i, j) or nil
local m2 = gate_text and body:sub(1, i - 1) .. body:sub(j + 1) or nil
m2 = m2 and swap(m2, "\n## 2 — ", "\n" .. gate_text .. "\n## 2 — ") or nil
refused("a gate moved after §1 is refused", m2)
-- ARM 3: the §1 banner dropped.
refused("a §1 heading without DESTRUCTIVE is refused",
    swap(body, "## 1 — Curl-install the latest release (DESTRUCTIVE", "## 1 — Curl-install the latest release ("))
-- ARM 4: §2 forgets one platform.
refused("§2 without the per-platform Windows line is refused", swap(body, "- **Windows**:", "- Windows:"))
-- ARM 5: the old §2 gate restored.
refused("the old §2 '=0, stop here' gate is refused",
    swap(body, "## 2 — Full substrate reset (DESTRUCTIVE: the rest of the destruction)\n",
        "## 2 — Full substrate reset (DESTRUCTIVE: the rest of the destruction)\n\nIf `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`, stop here, write a plan blocker, and\npush it.\n"))

if fails > 0 then verdict.refused("smoke-gate-precedes-destruction", fails .. "-of-" .. arms .. "-arms-failed") end
verdict.ok("smoke-gate-precedes-destruction:" .. arms)
