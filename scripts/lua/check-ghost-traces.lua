-- @trace order:1842-2q4g, spec:ci-release
-- @env TILLANDSIAS_GHOST_TRACE_ROOT
-- @read-env TILLANDSIAS_GHOST_TRACE_ROOT
--
-- check-ghost-traces.lua — the ghost-trace ratchet at the preflight door.
--
-- WHY. scripts/trace-coverage.sh --gate used to run only at the END of the full
-- gate, so a one-line trace naming an absent spec cost an hour-long eviction
-- (#607, 2026-10-23, spec:forge-container). The same check takes well under a
-- second (measured 0.4 s), far inside the door's per-guard deadline, so it is
-- asked here, over the whole tree, with the gate's own semantics: a ghost not
-- in openspec/ghost-trace-baseline.txt is refused and NAMED, and a baseline
-- entry that is no longer a ghost is refused too (the baseline only shrinks).
--
-- The tree is TILLANDSIAS_GHOST_TRACE_ROOT when set (the fixture's scratch
-- trees), else the repository root.
--
-- VERDICTS: ok:ghost-traces:<gate line> | violation:ghost-traces:<n> line(s)

local root = env.get("TILLANDSIAS_GHOST_TRACE_ROOT")
if root == nil or root == "" then
    local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
    root = text.trim(top.stdout or "")
end
if root == "" then
    verdict.could_not_run("ghost-traces", "no tree root: git rev-parse --show-toplevel did not answer")
end
local script = root .. "/scripts/trace-coverage.sh"
if not fs.exists(script) then
    verdict.could_not_run("ghost-traces", script .. " is absent, so nothing was learned about the tree")
end

local r = proc.run({ argv = { "bash", script, "--gate" }, cwd = root, timeout_ms = 60000 })
local body = (r.stdout or "") .. (r.stderr or "")
if r.status == "exited" and r.code == 0 then
    verdict.emit("ok:ghost-traces:" .. text.trim(r.stdout or ""), 0)
end
if r.status ~= "exited" or (r.code ~= 1) then
    verdict.could_not_run("ghost-traces", "trace-coverage.sh --gate did not decide: " .. tostring(r.status) .. " " .. tostring(r.code))
end
local n = 0
for _, l in ipairs(text.lines(body)) do
    if l ~= "" then
        log.raw("  " .. l)
        if l:match("^%s+spec:") then n = n + 1 end
    end
end
log.raw("  why: a @trace names a spec that does not exist; the full gate refuses this tree an hour from now")
log.raw("  remedy: create the spec, archive the change defining it, or delete the annotation")
verdict.emit("violation:ghost-traces:" .. n .. " spec(s)", 1)
