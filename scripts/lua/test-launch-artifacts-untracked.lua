-- @trace spec:forge-as-only-runtime, order:444, order:1598-kgra
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-launch-artifacts-untracked.lua — scripts/lua/check-launch-artifacts-untracked.lua
-- on scratch repos (order 444), so each of its refusals is seen to fire and
-- its scan is exercised. The real tree has no entrypoint write into a harness
-- dir at all, so without these arms the scan would never run on a line.
--
--   1 CLEAN       artifacts untracked and ignored, no harness write: ok
--   2 TRACKED     .opencode/package-lock.json committed: fail:tracked-...
--   3 UNIGNORED   .forge-startup-context.md not in .gitignore: fail:unignored-...
--   4 UNMANIFEST  an entrypoint writes .codex/new-state.json: fail:unmanifested-...
--   5 IGNORED     the same write, with .codex/ in .gitignore: ok
--   6 COMMENT     the write only in a comment: ok
--   7 READERS     the retired .sh path has no reader in scripts/, the gate
--                 steps or the litmus specs; the count searched is printed
--
-- Terminal line: ok:launch-artifacts-untracked-fixture:<n> or
-- refused:launch-artifacts-untracked-fixture:<failed>.
--
-- Usage: TILLANDSIAS_PLAN_BIN=<bin> tillandsias-plan script run scripts/lua/test-launch-artifacts-untracked.lua

local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or env.get("TILLANDSIAS_PLAN_BIN") or ""
if PLAN == "" then
    verdict.emit("skip:launch-artifacts-untracked-fixture:no-script-runner — set TILLANDSIAS_PLAN_BIN", 0)
end
local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local CHECK = "scripts/lua/check-launch-artifacts-untracked.lua"
local REL = "target/plan-scratch/launch-artifacts-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local passed, failed = 0, 0
local function ok(m) out.line("ok: " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL: " .. m); failed = failed + 1 end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end

local IGNORE = ".opencode/package-lock.json\n.opencode/node_modules\n.forge-startup-context.md\n"
local BENIGN = "#!/usr/bin/env bash\necho starting\n"
-- repo(name, gitignore, entrypoint, tracked?): a scratch checkout to judge.
local function repo(name, gitignore, entry, track)
    local d = REL .. "/" .. name
    fs.mkdir(d .. "/images/default")
    fs.write(d .. "/.gitignore", gitignore)
    fs.write(d .. "/images/default/entrypoint-forge-fixture.sh", entry)
    fs.write(d .. "/images/default/lib-common.sh", "#!/usr/bin/env bash\n:\n")
    local function g(args)
        local argv = { "git", "-C", ROOT .. "/" .. d, "-c", "user.name=fixture", "-c", "user.email=fixture@local", "-c", "commit.gpgsign=false" }
        for _, a in ipairs(args) do argv[#argv + 1] = a end
        proc.run({ argv = argv, timeout_ms = 30000 })
    end
    g({ "init", "-q" })
    if track then
        fs.mkdir(d .. "/.opencode")
        fs.write(d .. "/.opencode/package-lock.json", "{}\n")
        g({ "add", "-f", ".opencode/package-lock.json" })
    end
    g({ "add", "-A" }); g({ "commit", "-qm", "fixture" })
    return d
end
local function judge(d)
    local r = proc.run({ argv = { PLAN, "script", "run", ROOT .. "/" .. CHECK, "--", d }, cwd = ROOT, timeout_ms = 60000 })
    return (r.status == "exited" and r.code or -1), text.trim(r.stdout or "")
end
local function expect(label, d, want_rc, want)
    local rc, o = judge(d)
    if rc == want_rc and has(o, want) then ok(label .. " (" .. want .. ")")
    else bad(label .. ": rc=" .. rc .. " out=" .. o:sub(1, 200)) end
end

expect("clean repo passes", repo("clean", IGNORE, BENIGN), 0, "ok:launch-artifacts-untracked")
expect("a tracked artifact is refused", repo("tracked", IGNORE, BENIGN, true), 1, "fail:tracked-launch-artifact:.opencode/package-lock.json")
expect("an unignored artifact is refused", repo("unignored", ".opencode/package-lock.json\n.opencode/node_modules\n", BENIGN), 1,
    "fail:unignored-launch-artifact:.forge-startup-context.md")
local WRITES = BENIGN .. 'echo "{}" > .codex/new-state.json\n'
expect("an unmanifested entrypoint write is refused", repo("unmanifested", IGNORE, WRITES), 1,
    "fail:unmanifested-launch-artifact:.codex/new-state.json")
expect("the same write covered by .gitignore passes", repo("ignored", IGNORE .. ".codex/\n", WRITES), 0, "ok:launch-artifacts-untracked")
expect("a write only in a comment passes", repo("comment", IGNORE, BENIGN .. '# echo "{}" > .codex/new-state.json\n'), 0, "ok:launch-artifacts-untracked")

-- 7: the retired .sh path, assembled so this file cannot match itself.
local NEEDLE = "scripts/check-launch-artifacts-untracked" .. ".sh"
local SELF = "scripts/lua/test-launch-artifacts-untracked.lua"
local searched, hits = 0, {}
for _, root in ipairs({ "scripts", "openspec/litmus-tests" }) do
    for _, f in ipairs(fs.walk(root)) do
        if f ~= SELF and (f:sub(-3) == ".sh" or f:sub(-4) == ".lua" or f:sub(-5) == ".step" or f:sub(-5) == ".yaml") then
            searched = searched + 1
            local okr, body = pcall(fs.read, f)
            if okr and body and has(body, NEEDLE) then hits[#hits + 1] = f end
        end
    end
end
if #hits == 0 and searched > 100 then
    ok("the retired .sh path has 0 readers (" .. searched .. " files searched: scripts/, gate steps, litmus specs)")
else
    bad("readers of the retired .sh path: " .. #hits .. " in " .. searched .. " files: " .. table.concat(hits, ", "))
end

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL } })
if failed == 0 then verdict.emit("ok:launch-artifacts-untracked-fixture:" .. passed, 0) end
verdict.emit("refused:launch-artifacts-untracked-fixture:" .. failed, 1)
