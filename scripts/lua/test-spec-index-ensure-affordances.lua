-- @env PATH
-- @trace order:1247-amcu, spec:forge-environment-discoverability
--
-- test-spec-index-ensure-affordances.lua — every refusal of
-- scripts/spec-index-ensure.sh (the spec RAG index builder) says WHY it
-- refused and WHAT would make it not a refusal, as labelled "  why:" /
-- "  remedy:" lines on stderr beside its unchanged stdout verdict (1247-amcu).
--
--   1 a chunker that fails refuses blocked:spec-index:chunker-failed with why
--     and remedy (a stub tillandsias-plan whose spec-index exits 3);
--   2 a chunker that writes no chunks refuses blocked:spec-index:no-chunks
--     with why and remedy;
--   3 STATIC: every verdict the script emits carries an _afford call on its
--     line or an `affordance-ok:` marker on the line above (the four sites
--     that print their own explanation block), so a refusal added later
--     without one fails here.
--
-- Each run is hermetic: HOME and TMPDIR are a scratch directory, podman is
-- not consulted (TILLANDSIAS_SPEC_INDEX_NO_PODMAN=1), and the embedding
-- endpoint is a closed port, never reached because the chunker refuses first.
--
-- Usage: tillandsias-plan script run scripts/lua/test-spec-index-ensure-affordances.lua
-- Verdict: ok:spec-index-ensure-affordances:<n> arms | violation:spec-index-ensure-affordances:<arm>

local SUBJECT = "scripts/spec-index-ensure.sh"
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

-- fs.write is held to the repository, so the sandbox lives under target/.
local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local scratch = root .. "/target/plan-scratch/sie-afford-" .. tostring(time.now_ms())
if not proc.run{ argv = { "mkdir", "-p", scratch } }.ok then
    verdict.emit("could-not-run:spec-index-ensure-affordances:no-scratch", 2)
end

-- A stub plan binary: `spec-index` does what `mode` says, anything else is
-- handed to the real binary the runner resolved (TILLANDSIAS_SCRIPT_RUNNER_BIN
-- is not passed through @env, so the stub names it by the path of `self`).
local real = text.trim(proc.run{ argv = { "sh", "-c", "command -v tillandsias-plan || true" } }.stdout or "")
if real == "" then real = "target/release/tillandsias-plan" end
local function stub(mode)
    local path = scratch .. "/plan-" .. mode
    local body = "#!/bin/sh\n"
    if mode == "fails" then
        body = body .. 'if [ "$1" = spec-index ]; then exit 3; fi\n'
    else
        body = body .. 'if [ "$1" = spec-index ]; then while [ "$#" -gt 0 ]; do [ "$1" = --out ] && : > "$2/chunks.jsonl"; shift; done; exit 0; fi\n'
    end
    body = body .. 'exec "' .. real .. '" "$@"\n'
    fs.write(path, body)
    proc.run{ argv = { "chmod", "+x", path } }
    return path
end

local function run(plan)
    local r = proc.run{ argv = { "bash", SUBJECT }, timeout_ms = 120000, env = {
        HOME = scratch, TMPDIR = scratch, TILLANDSIAS_PLAN_BIN = plan,
        TILLANDSIAS_SPEC_INDEX_NO_PODMAN = "1",
        TILLANDSIAS_EMBED_ENDPOINT = "http://127.0.0.1:9/v1",
    } }
    return r.code, text.trim(r.stdout or ""), r.stderr or ""
end

-- 1 the chunker fails.
local c1, o1, e1 = run(stub("fails"))
arm("1 a failing chunker refuses chunker-failed with why and remedy",
    c1 == 1 and o1:find("blocked:spec-index:chunker-failed", 1, true) ~= nil and afforded(e1),
    "rc=" .. tostring(c1) .. " stdout=" .. o1 .. " stderr=" .. e1)

-- 2 the chunker writes nothing.
local c2, o2, e2 = run(stub("empty"))
arm("2 an empty chunk file refuses no-chunks with why and remedy",
    c2 == 1 and o2:find("blocked:spec-index:no-chunks", 1, true) ~= nil and afforded(e2),
    "rc=" .. tostring(c2) .. " stdout=" .. o2 .. " stderr=" .. e2)

-- 3 static: no verdict site without its affordance.
local src = fs.read(SUBJECT) or ""
local prev, bare, n = "", {}, 0
for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    local emits = (line:find('echo "blocked:', 1, true) or line:find('echo "refused:', 1, true)
        or line:find('echo "violation:', 1, true)) and not line:match("^%s*#")
    if emits and not line:find("_afford ", 1, true) and not prev:find("affordance-ok:", 1, true) then
        bare[#bare + 1] = tostring(n)
    end
    prev = line
end
arm("3 every verdict site carries _afford or an affordance-ok reason",
    #src > 0 and #bare == 0, "bare verdict lines: " .. table.concat(bare, ","))

proc.run{ argv = { "rm", "-rf", scratch } }
if #failed > 0 then
    verdict.emit("violation:spec-index-ensure-affordances:" .. failed[1]:gsub("%s+", "-"), 1)
end
verdict.emit("ok:spec-index-ensure-affordances:" .. arms .. " arms", 0)
