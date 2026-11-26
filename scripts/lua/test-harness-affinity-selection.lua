-- @trace order:555, order:2344-zk8r, spec:ci-release
--
-- test-harness-affinity-selection.lua — a forge cycle that knows its harness
-- (TILLANDSIAS_HOST_KIND=forge + TILLANDSIAS_AGENT) prefers a ready packet tagged
-- [harness-validation, <that harness>], and falls back to normal selection, never
-- idle. Drives scripts/select-work-batch.sh through the TILLANDSIAS_PLAN_BIN seam.
-- Ported from the .sh (2344-zk8r).
--
--   1 affinity fires: the matching packet heads the batch, the header says harness=<pid>
--   2 no matching packet ready: a normal non-empty batch, no harness=
--   3 a NON-forge host with TILLANDSIAS_AGENT set: no harness=
--   4 the match already sits in the chosen epic: moved to the head, no duplicate, same size
--   5 an agent name that is not tag-shaped: no harness=, batch intact
--   6 a cross-branch check that could not fold (rc 2): the note says so, batch unchanged
--     (2323-wwaa: the check is a stub, so this clone's siblings are not read)
--
-- Verdict: ok:harness-affinity-selection:<n> | violation:harness-affinity-selection:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("harness-affinity-selection")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local W = T:scratch()

local function packet(id, order, prio, epic, tags)
    return "  - packet_id: " .. id .. "\n    order: " .. order .. "\n    status: ready\n    desired_release: v0.5\n"
        .. "    pickup_role: linux\n    priority: " .. prio .. "\n    release_target: " .. epic
        .. "\n    capability_tags: [" .. tags .. "]\n"
end
local HEAD = "plan_index:\n  default_status_values: [ready, completed]\npackets:\n"
-- A: the harness packet lives OUTSIDE the general epic. B: INSIDE the only epic.
fs.write(W.rel .. "/ledger-a.yaml", HEAD
    .. packet("opencode-harness-validation", "920-hopc", "p2", "harness-epic", "harness-validation, opencode")
    .. packet("general-one", "920-gaaa", "p1", "general-epic", "plan")
    .. packet("general-two", "920-gbbb", "p2", "general-epic", "plan"))
fs.write(W.rel .. "/ledger-b.yaml", HEAD
    .. packet("opencode-harness-validation", "920-hopc", "p3", "harness-epic", "harness-validation, opencode")
    .. packet("sibling-one", "920-saaa", "p1", "harness-epic", "plan")
    .. packet("sibling-two", "920-sbbb", "p2", "harness-epic", "plan"))
for _, k in ipairs{ "a", "b" } do
    fs.write(W.rel .. "/plan-" .. k, '#!/usr/bin/env bash\nexec "' .. PLAN .. '" --index "' .. W.abs .. "/ledger-" .. k .. '.yaml" "$@"\n')
end
fs.write(W.rel .. "/xbranch", '#!/usr/bin/env bash\nexit "${XB_STUB_RC:-0}"\n')
T:must{ "chmod", "+x", W.abs .. "/plan-a", W.abs .. "/plan-b", W.abs .. "/xbranch" }

-- The tier and capability set are pinned: a 4-core host must not trip the low-end gate.
local function select(ledger, extra)
    local e = { TILLANDSIAS_PLAN_BIN = W.abs .. "/plan-" .. ledger, TILLANDSIAS_HOST_TIER = "general",
        TILLANDSIAS_HOST_CAPS = "nix", TILLANDSIAS_XBRANCH_CHECK = W.abs .. "/xbranch" }
    for k, v in pairs(extra) do e[k] = v end
    local r = T:run{ SH, ROOT .. "/scripts/select-work-batch.sh", "linux", "--release", "v0.5", "--budget", "3",
        "--seed", "harness-fixture", cwd = ROOT, env = e, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local s = { text = (r.stdout or "") .. (r.stderr or ""), ids = {}, dup = nil, rc = r.code }
    s.header = s.text:match("^[^\n]*")
    s.harness = s.header:match(" harness=(%S+)")
    local seen = {}
    for pid in ("\n" .. s.text):gmatch("\npacket\t[^\t\n]*\t([^\t\n]*)") do
        s.ids[#s.ids + 1] = pid
        if seen[pid] then s.dup = pid end
        seen[pid] = true
    end
    return s
end
local function got(s) return "rc=" .. tostring(s.rc) .. " head=" .. tostring(s.ids[1]) .. " n=" .. #s.ids .. " header: " .. s.header end
local WANT = "opencode-harness-validation"

local s = select("a", { TILLANDSIAS_HOST_KIND = "forge", TILLANDSIAS_AGENT = "opencode" })
T:arm("1 affinity fires: the matching packet heads the batch", s.harness == WANT and s.ids[1] == WANT, got(s))

s = select("a", { TILLANDSIAS_HOST_KIND = "forge", TILLANDSIAS_AGENT = "codex" })
T:arm("2 no match: a normal non-empty batch, no harness=", not s.harness and #s.ids >= 1, got(s))

s = select("a", { TILLANDSIAS_AGENT = "opencode" })
T:arm("3 a bare-metal host never takes the branch", not s.harness, got(s))

s = select("b", { TILLANDSIAS_HOST_KIND = "forge", TILLANDSIAS_AGENT = "opencode" })
T:arm("4 a match in the chosen epic is moved to the head, not duplicated",
    s.harness == WANT and s.ids[1] == WANT and not s.dup and #s.ids == 3, "dup=" .. tostring(s.dup) .. " " .. got(s))

local BAD = { TILLANDSIAS_HOST_KIND = "forge", TILLANDSIAS_AGENT = "opencode; rm -rf /" }
local clean = select("b", BAD)
T:arm("5 a non-tag-shaped agent name falls back silently", not clean.harness and #clean.ids >= 1, got(clean))

BAD.XB_STUB_RC = "2"
s = select("b", BAD)
T:arm("6 could-not-fold is said and nothing is dropped",
    s.text:find("cross-branch: could not fold sibling branches", 1, true) and not clean.text:find("cross-branch: ", 1, true)
    and #s.ids == #clean.ids, "clean n=" .. #clean.ids .. " " .. got(s))
T:finish({ ok = function(n) return "ok:harness-affinity-selection:" .. n end })
