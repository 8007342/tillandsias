-- @trace order:1594-mtc3
--
-- test-relay-preflight-deleted-fixture.lua — relay-preflight's phase 5 does not
-- select a test-*.sh the diff DELETES as a touched fixture.
--
-- MEASURED by macuahuitl-fedora 2026-10-11: relay-preflight --keep-going on
-- #314, a shell->lua port that deletes scripts/test-cycle-metrics-mix-label.sh,
-- listed fixture:test-cycle-metrics-mix-label and reported it red, "No such
-- file". _set_a took test-*.sh names from DIFF_SCRIPTS, which includes
-- deletions, with no existence check; _set_b already had one.
--
-- The fixture runs scripts/relay-preflight.sh's own phase-5 selection (from
-- `_all_fixtures=` to `fixtures=`) in a scratch repo, with a DIFF_SCRIPTS that
-- deletes test-gone.sh, modifies test-kept.sh and adds test-added.sh:
--   1 PRE-FIX  the block with its BEGIN/END-SET-A-EXISTS filter stripped
--              selects the deleted test-gone.sh
--   2 FIXED    the block as it stands does not select test-gone.sh
--   3 CONTROL  the fixed block still selects the modified and the added one
--
-- Terminal line: ok:relay-preflight-deleted-fixture:<n> or
-- refused:relay-preflight-deleted-fixture:<failed>.
--
-- Usage: tillandsias-plan script run scripts/lua/test-relay-preflight-deleted-fixture.lua

local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local REL = "target/plan-scratch/relay-deleted-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local S = ROOT .. "/" .. REL
fs.mkdir(REL .. "/repo/scripts")
local passed, failed = 0, 0
local function ok(m) out.line("ok: " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL: " .. m); failed = failed + 1 end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end

local src = fs.read("scripts/relay-preflight.sh") or ""
local block = src:match("\n(_all_fixtures=.-\nfixtures=[^\n]*)\n")
local pre = block and block:gsub("# BEGIN%-SET%-A%-EXISTS\n.-# END%-SET%-A%-EXISTS\n", "")
if not block or pre == block then
    bad("premise: phase 5's selection block, or its BEGIN/END-SET-A-EXISTS filter, was not found in scripts/relay-preflight.sh")
    proc.run({ argv = { "rm", "-rf", S } })
    verdict.emit("refused:relay-preflight-deleted-fixture:" .. failed, 1)
end

-- The scratch repo: test-kept.sh and test-added.sh exist; test-gone.sh was deleted.
local REPO = S .. "/repo"
local function git(args)
    local argv = { "git", "-C", REPO, "-c", "user.name=fixture", "-c", "user.email=fixture@local", "-c", "commit.gpgsign=false" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return proc.run({ argv = argv, timeout_ms = 30000 })
end
git({ "init", "-q" })
fs.write(REL .. "/repo/scripts/test-kept.sh", "#!/usr/bin/env bash\necho kept\n")
fs.write(REL .. "/repo/scripts/test-added.sh", "#!/usr/bin/env bash\necho added\n")
git({ "add", "-A" }); git({ "commit", "-qm", "fixtures" })

local DIFF = "scripts/test-gone.sh\nscripts/test-kept.sh\nscripts/test-added.sh"
local function select(name, body)
    fs.write(REL .. "/" .. name, "cd \"$1\" || exit 2\nDIFF_SCRIPTS=\"$2\"\n" .. body .. "\nprintf 'selected:%s\\n' $fixtures\n")
    local r = proc.run({ argv = { "bash", S .. "/" .. name, REPO, DIFF }, timeout_ms = 30000 })
    return (r.stdout or "") .. (r.stderr or "")
end

local o_pre = select("pre-fix.sh", pre)
if has(o_pre, "selected:scripts/test-gone.sh") then ok("pre-fix phase 5 selects the deleted scripts/test-gone.sh")
else bad("pre-fix phase 5 did not select the deleted fixture: " .. o_pre:sub(1, 200)) end

local o_fix = select("fixed.sh", block)
if not has(o_fix, "test-gone.sh") then ok("fixed phase 5 does not select the deleted scripts/test-gone.sh")
else bad("fixed phase 5 still selects the deleted fixture: " .. o_fix:sub(1, 200)) end
if has(o_fix, "selected:scripts/test-kept.sh") and has(o_fix, "selected:scripts/test-added.sh") then
    ok("fixed phase 5 still selects the modified test-kept.sh and the added test-added.sh")
else bad("fixed phase 5 lost a present fixture: " .. o_fix:sub(1, 200)) end

proc.run({ argv = { "rm", "-rf", S } })
if failed == 0 then verdict.emit("ok:relay-preflight-deleted-fixture:" .. passed, 0) end
verdict.emit("refused:relay-preflight-deleted-fixture:" .. failed, 1)
