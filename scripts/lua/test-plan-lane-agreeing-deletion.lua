-- @trace order:1260-4a59, order:2400-prg4, spec:ci-release
--
-- test-plan-lane-agreeing-deletion.lua — the plan-only lane must treat a path ABSENT ON
-- BOTH SIDES as agreement, not as an obligation. Ported from
-- test-plan-lane-agreeing-deletion.sh (2400-prg4); same six arms, in its order.
--
-- 1152-y3bv's exemption drops a non-plan path whose pushed blob is byte-identical to
-- trunk's; it was guarded by "exists on trunk", so a path deleted on BOTH sides was refused
-- and a stale platform branch could not catch up by itself.
--
-- The lane's decision is a pure function of two blob lookups, so arms 1-5 exercise a COPY of
-- the `_1152_` branch of scripts/hooks/pre-push-local-gate.sh (as the .sh did), run by a POSIX
-- shell; arm 6 asserts the shipped guard carries the branch, so the copy cannot silently be
-- the only place it lives.
--
--   1  absent on both -> dropped:agreeing-deletion
--   2  MUTATION: absent on trunk, PRESENT in the push -> still refused
--   3  byte-identical -> dropped:byte-identical (1152-y3bv unregressed)
--   4  a genuine difference -> refused
--   5  present on trunk, deleted in the push -> refused
--   6  the shipped guard carries the agreeing-deletion branch
--
-- GRAMMAR ok:plan-lane-agreeing-deletion:<n> arms | violation:plan-lane-agreeing-deletion:<n>-failed
--       | skip:plan-lane-agreeing-deletion:guard-absent

local fixture = require "common.fixture"
local T = fixture.new("plan-lane-agreeing-deletion")
local SH = fixture.posix_shell()
local GUARD = "scripts/hooks/pre-push-local-gate.sh"
if not fs.exists(GUARD) then T:skip("guard-absent") end
local src = fs.read(GUARD) or ""
local W = T:scratch()

-- The copy the .sh carried, kept verbatim as the decision under test.
local HARNESS = [[
_lane_verdict() {
    _1152_trunk_blob="$1"; _1152_push_blob="$2"
    if [ -z "$_1152_trunk_blob" ] && [ -z "$_1152_push_blob" ]; then
        echo "dropped:agreeing-deletion"; return 0
    fi
    if [ -n "$_1152_trunk_blob" ]; then
        if [ -n "$_1152_push_blob" ] && [ "$_1152_trunk_blob" = "$_1152_push_blob" ]; then
            echo "dropped:byte-identical"; return 0
        fi
    fi
    echo "refused"; return 1
}
_lane_verdict "$1" "$2"
]]
fs.write(W.rel .. "/lane.sh", HARNESS)
local function verdict_for(trunk, push)
    local r = T:run{ SH, W.abs .. "/lane.sh", trunk, push, timeout_ms = 10000 }
    return text.trim(r.stdout or "")
end

local o = verdict_for("", "")
T:arm("ARM 1 absent on trunk AND absent in the push is dropped", o == "dropped:agreeing-deletion", o)
o = verdict_for("", "aaaa111")
T:arm("ARM 2 MUTATION: absent on trunk but PRESENT in the push still refuses", o == "refused", o)
o = verdict_for("bbbb222", "bbbb222")
T:arm("ARM 3 byte-identical to trunk is still dropped (1152-y3bv unregressed)", o == "dropped:byte-identical", o)
o = verdict_for("bbbb222", "cccc333")
T:arm("ARM 4 a path differing from trunk still refuses", o == "refused", o)
o = verdict_for("bbbb222", "")
T:arm("ARM 5 a deletion trunk has not made still refuses", o == "refused", o)

T:arm("ARM 6 the shipped guard carries the agreeing-deletion branch",
    text.contains(src, "absent on origin/linux-next AND absent in this push"),
    "the shipped guard does NOT carry it — this test exercises a copy only")

T:finish()
