-- @trace order:964-zedm, order:967-xq5e, order:2357-42x9
--
-- test-spec-index-staging-capacity.lua — spec-index-ensure.sh stages where the payload FITS (the
-- index root), not where TMPDIR points. Ported from the .sh of the same name (2357-42x9). In a
-- forge /tmp is a 256 MB tmpfs while the index root is on a 1.2 TB overlay, and a cold build died
-- with ENOSPC. STATIC over the script. The .sh also ran it with the override set and asserted
-- only that the directory still existed, which nothing could fail; that arm is not carried over.
--
--   1 staging is anchored to the index root, with the operator override first
--   2 the ambient TMPDIR form comes only after it (the fallback)
--   3 the ENOSPC verdict names the directory, the root, the space and the override
--   4 NC the unwritable-root fallback is still there
--
-- Usage: tillandsias-plan script run scripts/lua/test-spec-index-staging-capacity.lua
-- Verdict: ok:spec-index-staging-capacity:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("spec-index-staging-capacity")
local SRC = fs.read("scripts/spec-index-ensure.sh"):gsub("\r", "")
local function has(s) return text.contains(SRC, s) end
T:arm("1a staging is anchored to the index root, the override first", has('_stage_parent="${TILLANDSIAS_SPEC_INDEX_TMPDIR:-$INDEX_ROOT}"'), "_stage_parent is not that")
T:arm("1b and the staging dir is made there", has('mktemp -d "$_stage_parent/.spec-index-ensure.XXXXXX"'), "mktemp is elsewhere")
local ambient, anchored = SRC:find('mktemp -d "${TMPDIR:-/tmp}/spec-index-ensure', 1, true), SRC:find("_stage_parent=", 1, true)
T:arm("2 the ambient TMPDIR form is only reachable after it", anchored ~= nil and (ambient == nil or ambient > anchored), "ambient=" .. tostring(ambient) .. " anchored=" .. tostring(anchored))
-- The echo, not the header comment that lists the token.
local a = SRC:find('echo "blocked:spec-index:payload-failed', 1, true)
local z = a and SRC:find("exit 1; }", a, true)
local block, missing = a and z and SRC:sub(a, z) or "", {}
for _, s in ipairs{ "staging dir:", "index root:", "df -Ph", "TILLANDSIAS_SPEC_INDEX_TMPDIR" } do
    if not text.contains(block, s) then missing[#missing + 1] = s end
end
T:arm("3 the payload-failed verdict names the directory, the root, the space and the override", #missing == 0, "missing: " .. table.concat(missing, ", "))
T:arm("4 NC the unwritable-root fallback is there and says so", has("blocked:spec-index:no-tmpdir") and has("could not create a staging dir under"), "missing or silent")
T:finish()
