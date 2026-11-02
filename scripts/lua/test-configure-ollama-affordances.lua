-- @env PATH
-- @trace order:1247-amcu, order:1249-xngp, spec:inference-container
--
-- test-configure-ollama-affordances.lua — every refusal of
-- scripts/configure-ollama.sh (the bare-metal ollama for the local expert lane)
-- says WHY it refused and WHAT would make it not a refusal (1247-amcu): either
-- labelled "  why:" / "  remedy:" lines on stderr, or the script's own WHY /
-- WHAT TO DO prose after the verdict, marked `affordance-ok:` on the line above.
--
-- Most refusals sit behind a download, a model pull or a started engine, which
-- a hermetic fixture must not perform; those are pinned STATICALLY. One is RUN:
-- a TILLANDSIAS_OLLAMA_BIN_DIR beneath a regular file cannot be created, so the
-- script refuses before it fetches anything.
--
--   1 an uncreatable bin dir refuses install-failed with why and remedy, and
--     downloads nothing;
--   2 STATIC: every verdict the script emits carries an _afford call on its
--     line or an `affordance-ok:` marker on the line above.
--
-- Usage: tillandsias-plan script run scripts/lua/test-configure-ollama-affordances.lua
-- Verdict: ok:configure-ollama-affordances:<n> arms | violation:configure-ollama-affordances:<arm>

local SUBJECT = "scripts/configure-ollama.sh"
local arms, failed = 0, {}

local function arm(name, cond, detail)
    if cond then
        arms = arms + 1
        out.line("ok:   " .. name)
    else
        failed[#failed + 1] = name
        out.line("FAIL: " .. name .. " — " .. tostring(detail))
    end
end

local function afforded(err)
    return err:find("  why: %S") ~= nil and err:find("  remedy: %S") ~= nil
end

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local scratch = root .. "/target/plan-scratch/co-afford-" .. tostring(time.now_ms())
proc.run{ argv = { "mkdir", "-p", scratch } }
fs.write(scratch .. "/blocker", "a file, so a directory beneath it cannot exist\n")

-- 1 the bin dir sits under a regular file: mkdir refuses before any fetch.
local r = proc.run{ argv = { "bash", SUBJECT }, timeout_ms = 60000, env = {
    HOME = scratch, TILLANDSIAS_OLLAMA_BIN_DIR = scratch .. "/blocker/bin",
    TILLANDSIAS_OLLAMA_INSTALL_UNIT = "0",
} }
local so, se = text.trim(r.stdout or ""), r.stderr or ""
arm("1 an uncreatable bin dir refuses install-failed with why and remedy",
    r.code == 1 and so:find("blocked:configure-ollama:install-failed", 1, true) ~= nil
        and not so:find("installing ollama", 1, true) and afforded(se),
    "rc=" .. tostring(r.code) .. " stdout=" .. so .. " stderr=" .. se)

-- 2 static: no verdict site without its affordance.
local src = fs.read(SUBJECT) or ""
local prev, bare, n = "", {}, 0
for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    local emits = (line:find('say "blocked:', 1, true) or line:find('say "refused:', 1, true)
        or line:find('echo "blocked:', 1, true) or line:find('echo "refused:', 1, true))
        and not line:match("^%s*#")
    if emits and not line:find("_afford ", 1, true) and not prev:find("affordance-ok:", 1, true) then
        bare[#bare + 1] = tostring(n)
    end
    prev = line
end
arm("2 every verdict site carries _afford or an affordance-ok reason",
    #src > 0 and #bare == 0, "bare verdict lines: " .. table.concat(bare, ","))

proc.run{ argv = { "rm", "-rf", scratch } }
if #failed > 0 then
    verdict.emit("violation:configure-ollama-affordances:" .. failed[1]:gsub("%s+", "-"), 1)
end
verdict.emit("ok:configure-ollama-affordances:" .. arms .. " arms", 0)
