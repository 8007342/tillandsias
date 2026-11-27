-- @trace order:970-7fqk, order:930-i6x4, order:1142-85zx, order:2360-ud6i, spec:ci-release
--
-- test-gate-stamp-names-content-movers.lua — `gate-stamp.sh movers` names paths whose
-- CONTENT moved, on the axis the staleness decision uses, not paths whose mtime moved.
-- Every arm stamps a throwaway repository, never this checkout: an unearned stamp in the
-- live one could let an ungated tree reach trunk. Ported from the .sh (2360-ud6i).
--
--   1 a stamp writes a manifest; an unchanged tree has no movers
--   2 content changed with an OLD mtime is named, and the mtime signal could not see it
--   3 an identical rewrite with a NEW mtime is not named, and the mtime signal names it.
--     2 and 3 are opposites: either alone passes for a guard that always says one thing
--   4 an added and a deleted path are both named
--   5 no manifest refuses (rc 2), never a clean list
--   6 verify does not rewrite the manifest: it would diff the tree against itself
--   7 the pre-push refusal calls movers through a variable it defines, and keeps the mtime
--     list as the live-writer hint it is
--   8 plan fast-lane paths are excluded as compute excludes them (movers once named 40
--     fragments that cannot be the cause), and only at top level
--
-- Verdict: ok:gate-stamp-names-content-movers:<n> arms | violation:gate-stamp-names-content-movers:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-stamp-names-content-movers")
local SH = fixture.posix_shell()
local HOOK = "scripts/hooks/pre-push-local-gate.sh"

local function stamp(d, verb, e)
    local r = T:run{ SH, "scripts/gate-stamp.sh", verb, cwd = d.abs, env = e, env_unset = { "TILLANDSIAS_*", "GIT_*", "CARGO_TARGET_DIR" } }
    return r.code, r.stdout or "", (r.stdout or "") .. (r.stderr or "")
end
local function repo(tag, plan)
    local d = T:git_repo(tag)
    fs.mkdir(d.rel .. "/scripts")
    fs.write(d.rel .. "/scripts/gate-stamp.sh", fs.read("scripts/gate-stamp.sh"))
    fs.write(d.rel .. "/a.txt", "alpha\n"); fs.write(d.rel .. "/b.txt", "beta\n")
    for p, s in pairs(plan or {}) do fs.mkdir(d.rel .. "/" .. p:match("^(.*)/")); fs.write(d.rel .. "/" .. p, s) end
    T:must{ "git", "-C", d.abs, "add", "-A" }; T:must{ "git", "-C", d.abs, "commit", "-qm", "base" }
    -- Stands in for the gate, which alone issues the one-shot pass token `write` requires
    -- (940-f77j), as test-gate-stamp-scope.lua does.
    local _, digest = stamp(d, "compute")
    fs.write(d.rel .. "/.git/tillandsias-gate-pass-token", "version 1\ndigest " .. text.trim(digest) .. "\ndispatch check\nissued now\n")
    local rc, _, all = stamp(d, "write")
    d.manifest, d.stamp = "/.git/tillandsias-gate-stamp-manifest", "/.git/tillandsias-gate-stamp"
    if rc ~= 0 then T:refuse("setup-failed", "stamp write: " .. all) end
    return d
end
local function movers(d) local _, o = stamp(d, "movers"); return o end
local function line(o, l) return ("\n" .. o):find("\n" .. l .. "\n", 1, true) ~= nil end
local function newer(d) return T:run{ "test", d.abs .. "/a.txt", "-nt", d.abs .. d.stamp }.code == 0 end

local d = repo("r1")
T:arm("1 a stamp write emits a manifest", fs.exists(d.rel .. d.manifest) and fs.read(d.rel .. d.manifest) ~= "", "no manifest")
local o = movers(d)
T:arm("1 an unchanged tree reports no movers", o == "", o)

d = repo("r2")
fs.write(d.rel .. "/a.txt", "alpha-CHANGED\n")
T:must{ "touch", "-r", d.abs .. d.stamp, d.abs .. "/a.txt" }
if T:run{ "touch", "-d", "-1 hour", d.abs .. "/a.txt" }.code ~= 0 then T:must{ "touch", "-t", "200001010000", d.abs .. "/a.txt" } end
o = movers(d)
T:arm("2 changed content with an OLD mtime is named", line(o, "modified\ta.txt"), o)
T:arm("2 and the mtime signal could NOT see it", not newer(d), "the arm did not separate the two questions")

d = repo("r3")
fs.write(d.rel .. "/a.txt", "alpha\n"); T:must{ "touch", d.abs .. "/a.txt" }
o = movers(d)
T:arm("3 an identical rewrite is not a content mover", o == "", o)
if newer(d) then T:arm("3 and the mtime signal DID name it", true) else out.line("note: the mtime did not move here, so the contrast was not exercised") end

d = repo("r4")
fs.write(d.rel .. "/c.txt", "new\n"); T:must{ "rm", "-f", d.abs .. "/b.txt" }
o = movers(d)
T:arm("4 an added path is named", line(o, "added\tc.txt"), o)
T:arm("4 a deleted path is named", line(o, "deleted\tb.txt"), o)

d = repo("r5")
T:must{ "rm", "-f", d.abs .. d.manifest }
fs.write(d.rel .. "/a.txt", "alpha-CHANGED\n")
local rc, _, all = stamp(d, "movers")
T:arm("5 a missing manifest answers unavailable at rc 2, not a clean list", rc == 2 and all:find("unavailable:no-manifest", 1, true), "rc=" .. tostring(rc) .. " " .. all)

d = repo("r6")
local before = fs.read(d.rel .. d.manifest)
fs.write(d.rel .. "/a.txt", "alpha-CHANGED\n")
stamp(d, "verify", { GATE_STAMP_EMIT_MANIFEST = "1" })
T:arm("6 verify does not rewrite the manifest, even with the flag exported", fs.read(d.rel .. d.manifest) == before, "it was rewritten")

d = repo("r8", { ["plan/index.d/00000000t000000z-probe-linux.yaml"] = "packets: []\n", ["plan/issues/a-top-level-note.md"] = "note\n" })
fs.write(d.rel .. "/plan/index.d/00000000t000000z-probe-linux.yaml", "packets: [changed]\n")
fs.write(d.rel .. "/plan/issues/a-top-level-note.md", "changed\n")
o = movers(d)
T:arm("8 fast-lane paths are excluded, as they are from the digest", o == "", o)
d = repo("r8b", { ["plan/issues/research/deep.md"] = "deep\n" })
fs.write(d.rel .. "/plan/issues/research/deep.md", "deep-CHANGED\n")
o = movers(d)
-- The STATE, not the path: an over-broad skip surfaces as `deleted`.
T:arm("8 a plan/issues SUBDIRECTORY path is still covered", line(o, "modified\tplan/issues/research/deep.md"), o)

-- 7: only reached when someone is blocked, so a broken one is invisible until then.
local hook = fs.read(HOOK)
T:arm("7 the hook invokes movers via a variable it defines itself", hook:find('REPO_ROOT/scripts/gate-stamp.sh" movers', 1, true) and not hook:find("HOOK_ROOT", 1, true), HOOK)
T:arm("7 the mtime list survives as the live-writer hint", hook:find("A LIVE-WRITER HINT, NOT THE CAUSE", 1, true), HOOK)
local r = T:run{ SH, "-n", HOOK, cwd = fixture.repo_root() }
T:arm("7 the hook parses", r.code == 0, r.stderr)
T:finish()
