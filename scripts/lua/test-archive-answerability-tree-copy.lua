-- @trace order:2187-9cws, order:1392-6tbs, order:964-js34
--
-- test-archive-answerability-tree-copy.lua — the answerability tree copy
-- skips an IGNORED symlink whose target does not exist (a nix `result`), on
-- both copy paths, and still copies a tracked symlink.
--
-- The block between # BEGIN-TREE-COPY and # END-TREE-COPY in
-- scripts/check-archive-answerability.sh is cut and driven against a scratch
-- git repo under target/plan-scratch. GNU tar and cp recreate a dangling link
-- happily, so the red is observed as PRESENCE, host-independently: before
-- 2187-9cws the copy carried `result`; on MSYS that is where tar died.
--
-- Arms: premise (cut found, scratch repo shaped), CP (fast path), TAR (cp
-- masked so the probe fails), and MUTANT (the prune loop removed: the link
-- is copied again, so the arms are not vacuous).

local SRC = "scripts/check-archive-answerability.sh"
local pass, fail = 0, 0
local function ok(m) log.raw("ok:   " .. m); pass = pass + 1 end
local function bad(m) log.raw("FAIL: " .. m); fail = fail + 1 end
local function sh(argv) return proc.run({ argv = argv, timeout_ms = 60000 }) end

local pw = sh({ "pwd" })
local ROOT = text.trim(pw.stdout)
local rel = "target/plan-scratch/aatc-" .. math.floor(time.now_ms())
local S = ROOT .. "/" .. rel
sh({ "mkdir", "-p", S .. "/repo/plan" })

local body = fs.read(SRC)
local cut = body:match("\n(# BEGIN%-TREE%-COPY.-\n# END%-TREE%-COPY)\n")
if not cut then
    verdict.emit("violation:archive-answerability-tree-copy:no-cut-markers", 1)
end
local LOOP_PAT = "\nwhile IFS= read %-r %-d '' _aa_ign; do\n.-\ndone < <%(git [^\n]*\n"
local mutant, nsub = cut:gsub(LOOP_PAT, "\n")

-- Scratch repo: a tracked file, a tracked valid symlink, an ignored dangling one.
local R = S .. "/repo"
fs.write(rel .. "/repo/.gitignore", "/result\n")
fs.write(rel .. "/repo/plan/index.yaml", "packets: []\n")
sh({ "git", "-C", R, "init", "-q" })
sh({ "ln", "-s", "plan/index.yaml", R .. "/tracked-link" })
sh({ "ln", "-s", "/nonexistent/nix/store/aatc-tillandsias-0.0.0", R .. "/result" })
sh({ "git", "-C", R, "add", ".gitignore", "plan/index.yaml", "tracked-link" })
local ign = sh({ "git", "-C", R, "ls-files", "-o", "-i", "--exclude-standard", "--directory" })
if nsub == 1 and ign.stdout:find("result", 1, true) and not ign.stdout:find("tracked-link", 1, true) then
    ok("premise: copy block cut, prune loop found once, result is ignored and dangling")
else
    bad("premise: nsub=" .. nsub .. " ignored=[" .. text.trim(ign.stdout) .. "]")
end

-- drive <name> <block> <mask_cp> -> tree path, rc
local function drive(name, block, mask_cp)
    local T, L = S .. "/" .. name .. "/tree", S .. "/" .. name .. "/log"
    sh({ "mkdir", "-p", T, L })
    local pre = "set -uo pipefail\nREPO_ROOT='" .. R .. "'\nWORK='" .. S .. "/" .. name ..
        "'\nTREE='" .. T .. "'\nLOG='" .. L .. "'\nNAME=archive-answerability\nKEEP=0\n"
    if mask_cp then pre = pre .. "cp() { return 1; }\n" end
    fs.write(rel .. "/" .. name .. ".sh", pre .. block .. "\necho copy-block-completed\n")
    local r = proc.run({ argv = { "bash", S .. "/" .. name .. ".sh" }, timeout_ms = 60000 })
    return T, r
end
local function present(p) return sh({ "test", "-L", p }).ok end

for _, arm in ipairs({ { "cp", false }, { "tar", true } }) do
    local T, r = drive(arm[1], cut, arm[2])
    local done = r.stdout:find("copy-block-completed", 1, true)
    if done and not present(T .. "/result") and present(T .. "/tracked-link")
        and sh({ "test", "-f", T .. "/plan/index.yaml" }).ok then
        ok(arm[1] .. ": the ignored dangling result is skipped; the tracked link and the ledger are copied")
    else
        bad(arm[1] .. ": completed=" .. tostring(done ~= nil) .. " result=" .. tostring(present(T .. "/result")) ..
            " tracked-link=" .. tostring(present(T .. "/tracked-link")) .. " out=" .. r.stdout .. r.stderr)
    end
end

local MT = drive("mutant", mutant, false)
if present(MT .. "/result") then
    ok("mutant: without the prune loop the dangling result is copied again (the arms are not vacuous)")
else
    bad("mutant: the link was skipped without the prune loop, so the arms prove nothing")
end

sh({ "find", S, "-delete" })
if fail > 0 then
    verdict.emit("violation:archive-answerability-tree-copy:" .. pass .. "/" .. (pass + fail), 1)
end
verdict.emit("ok:archive-answerability-tree-copy:" .. pass .. " arms", 0)
