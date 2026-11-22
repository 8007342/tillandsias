-- @trace plan/issues/forge-opsx-skill-sync-dirties-checkout-2026-07-31.md (order 540, reversed by 1440-w8g8), order:2201-opsx
-- @env PATH HOME
--
-- check-opsx-generated-dirt.lua: deterministic detector for launch-generated
-- opsx/openspec skill-sync dirt, which it REFUSES (order 1440-w8g8). Port of
-- check-opsx-generated-dirt.sh (order 2201-opsx).
--
-- WHY: until order 1422-w3p8, every forge launch ran the installed @latest
-- openspec CLI's `init` against the checkout, regenerating the tracked
-- opsx/openspec command/skill paths whenever its templates drifted, so the forge
-- started dirty. The operator ruled on 2026-09-27 that this dirt "should not
-- exist": 1422-w3p8 stopped the launch producing it, and 1440-w8g8 made this
-- detector REFUSE it, as a regression to report, never content to commit.
--
-- Grammar (exactly one line):
--   ^(ok:clean-tree|launch-dirt:opsx-only|non-opsx:[a-z0-9._/-]*)$
--     ok:clean-tree         nothing dirty
--     launch-dirt:opsx-only every dirty path is in the generated opsx set
--     non-opsx:<paths>      at least one dirty path is NOT in the generated set
--
-- Exit codes:
--   0 — ok:clean-tree. (The .sh exited 4 here. Order 2201-opsx moved it to the
--       house code 0 under the coordinator's policy (b): a clean tree is the ok
--       outcome, and nothing else returns 0 since 1440-w8g8 retired
--       ok:opsx-only. Its two readers, test-check-opsx-generated-dirt.sh and
--       meta-orchestration SKILL.md step 4a, change in the same PR.
--       check-resumable-claim-dirt.sh still prints ok:clean-tree with exit 4.)
--   5 — launch-dirt:opsx-only (refuse; report the launch regression)
--   3 — non-opsx (real dirt present; refuse)
--   2 — non-opsx:not-a-git-repo (the worktree could not be inspected)

-- the 44-path generated set: 11 commands and 11 skills, in each harness locus
local NAMES = { "apply", "archive", "bulk-archive", "continue", "explore", "ff",
    "new", "onboard", "propose", "sync", "verify" }
local SKILLS = { "apply-change", "archive-change", "bulk-archive-change",
    "continue-change", "explore", "ff-change", "new-change", "onboard", "propose",
    "sync-specs", "verify-change" }
local GENERATED = {}
for _, n in ipairs(NAMES) do
    GENERATED[".opencode/commands/opsx-" .. n .. ".md"] = true
    GENERATED[".claude/commands/opsx/" .. n .. ".md"] = true
end
for _, s in ipairs(SKILLS) do
    GENERATED[".opencode/skills/openspec-" .. s .. "/SKILL.md"] = true
    GENERATED[".claude/skills/openspec-" .. s .. "/SKILL.md"] = true
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
if top.status ~= "exited" or top.code ~= 0 then
    verdict.emit("non-opsx:not-a-git-repo", 2)
end
local ROOT = text.trim(top.stdout or "")

local st = proc.run({ argv = { "git", "-C", ROOT, "status", "--porcelain=v1", "-z", "--untracked-files=all" },
    timeout_ms = 120000 })
-- Each NUL-separated record is "XY <path>". As in the .sh (which turned NULs
-- into newlines and cut three characters), a rename's second record is read
-- the same way; byte-identical, quirk included.
-- Tracked dirt is listed before untracked paths, as the .sh's two arrays did.
local tracked, untracked = {}, {}
for rec in string.gmatch(st.stdout or "", "[^%z]+") do
    if rec:sub(1, 2) == "??" then untracked[#untracked + 1] = rec:sub(4)
    else tracked[#tracked + 1] = rec:sub(4) end
end
local dirty = tracked
for _, p in ipairs(untracked) do dirty[#dirty + 1] = p end

if #dirty == 0 then
    verdict.emit("ok:clean-tree", 0)
end

local non = {}
for _, p in ipairs(dirty) do
    if not GENERATED[p] then non[#non + 1] = p end
end
if #non > 0 then
    verdict.emit("non-opsx:" .. table.concat(non, ","), 3)
end
verdict.emit("launch-dirt:opsx-only", 5)
