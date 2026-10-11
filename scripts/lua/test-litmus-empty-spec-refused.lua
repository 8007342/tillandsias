-- @trace order:1460-3gja, order:1588-bzre
--
-- test-litmus-empty-spec-refused.lua — PORTED from
-- test-litmus-empty-spec-refused.sh (1588-bzre). run-litmus-test.sh given an
-- EXPLICIT empty spec name must refuse, not run every spec. Measured on
-- lenovinha 2026-09-28: a binding lookup returned nothing,
-- `run-litmus-test.sh "$spec"` ran with "", and every spec ran for 1h47m.
--
-- Arms:
--   1 EMPTY     an explicit "" exits 3 with refused:empty-litmus-spec-argument
--               and runs no test (a 60 s bound catches the pre-fix suite run)
--   2 NAMED     (negative control) a real spec name passes the parser: a named
--               spec plus an unknown flag stops in argument parsing (exit 3,
--               "Unknown option", no empty-spec refusal) before any setup
--               (yolanda 2026-09-28: a --list run stranded sidecar stamps)
--   3 READERS   the .sh's retired terminal lines (PASS:/FAILED: ...) have no
--               reader in scripts/, the gate steps or the litmus specs; the
--               count of files searched is printed, never a bare "none"
--
-- Terminal line (1588-bzre): ok:/refused: instead of the .sh's PASS:/FAILED:,
-- which nothing read (gate step 600 decides on the exit code); exit codes
-- unchanged.

local R = "scripts/run-litmus-test.sh"
local fails = 0
local function ok(m) out.line("ok:   " .. m) end
local function bad(m) out.line("FAIL: " .. m); fails = fails + 1 end
local function all(r) return (r.stdout or "") .. (r.stderr or "") end
local function rc(r)
    if r.status == "timed_out" then return 124 end
    return (r.status == "exited") and r.code or -1
end

local r1 = proc.run({ argv = { "bash", R, "", "--phase", "pre-build", "--size", "instant", "--compact" }, timeout_ms = 60000 })
if rc(r1) == 3 and text.contains(all(r1), "refused:empty-litmus-spec-argument") then
    ok("ARM1 an explicit empty spec is refused (rc=3) instead of running every spec")
else
    bad("ARM1 rc=" .. rc(r1) .. " (124 means it started running the suite)")
end

local r2 = proc.run({ argv = { "bash", R, "git-mirror-service", "--no-such-flag-1460" }, timeout_ms = 30000 })
local o2 = all(r2)
if rc(r2) == 3 and text.contains(o2, "Unknown option") and not text.contains(o2, "refused:empty-litmus-spec-argument") then
    ok("ARM2 a named spec is accepted by the parser (it reached the next argument)")
else
    local head = {}
    for k, l in ipairs(text.lines(o2)) do if k > 3 then break end head[#head + 1] = l end
    bad("ARM2 rc=" .. rc(r2) .. " out='" .. table.concat(head, "|") .. "'")
end

-- ARM 3: the retired terminal lines, assembled so this file cannot match itself.
local NEEDLES = { "PA" .. "SS: litmus-empty-spec-refused", "FAI" .. "LED: litmus-empty-spec-refused" }
local SELF = "scripts/lua/test-litmus-empty-spec-refused.lua"
local searched, hits = 0, {}
for _, root in ipairs({ "scripts", "openspec/litmus-tests" }) do
    for _, f in ipairs(fs.walk(root)) do
        if f ~= SELF and (f:sub(-3) == ".sh" or f:sub(-4) == ".lua" or f:sub(-5) == ".step" or f:sub(-5) == ".yaml") then
            searched = searched + 1
            local okr, body = pcall(fs.read, f)
            if okr then
                for _, n in ipairs(NEEDLES) do
                    if text.contains(body, n) then hits[#hits + 1] = f .. " (" .. n .. ")" end
                end
            end
        end
    end
end
if #hits == 0 and searched > 100 then
    ok("ARM3 the retired PASS:/FAILED: terminal lines have 0 readers (" .. searched .. " files searched: scripts/, gate steps, litmus specs)")
else
    bad("ARM3 readers of the retired terminal lines: " .. #hits .. " in " .. searched .. " files: " .. table.concat(hits, ", "))
end

if fails == 0 then verdict.emit("ok:litmus-empty-spec-refused:3", 0) end
verdict.emit("refused:litmus-empty-spec-refused:" .. fails, 1)
