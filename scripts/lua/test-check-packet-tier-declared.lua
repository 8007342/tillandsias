-- @trace order:1437-cr8u, order:2080-8i25
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- test-check-packet-tier-declared.lua: scripts/lua/check-packet-tier-declared.lua
-- (ported from the .sh by 2080-8i25) on four arms, each in its own scratch repo:
--   1 UNDECLARED  a new packet with neither field  -> advisory:packet-tier-undeclared:1
--   2 DECLARED    a new packet with a notes-line   -> ok:packet-tier-declared:1
--   3 EVENT-ONLY  an events: fragment, no packets: -> ok:packet-tier-declared:0
--   4 KNOWN       an undeclared packet_id the base already has -> ok:packet-tier-declared:0
-- Arms 3 and 4 are the negative controls; arm 1 is the positive one, and arm 2
-- proves a notes-line counts (the cardinality, not just non-emptiness).
local SUBJECT = "scripts/lua/check-packet-tier-declared.lua"
if not fs.exists(SUBJECT) then
    verdict.emit("violation:packet-tier-fixture:no-subject", 1, SUBJECT .. " does not exist")
end
local BIN = env.get("TILLANDSIAS_PLAN_BIN")
if BIN == nil or BIN == "" then BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if BIN == nil or BIN == "" then
    verdict.could_not_run("packet-tier-fixture", "no-plan-binary — set TILLANDSIAS_PLAN_BIN")
end
-- git, not pwd -P: a native Windows runner calls /c/... relative.
local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 10000 }).stdout or "")
if ROOT == "" then verdict.could_not_run("packet-tier-fixture", "git rev-parse gave no root") end

local stamp = time.iso_utc():gsub("%W", "") .. "-" .. tostring(math.random(100000, 999999))
local failed = {}

local function run_arm(n, name, base_files, new_files, want)
    local S = "target/plan-scratch/packet-tier-" .. stamp .. "-" .. n
    fs.mkdir(S .. "/scripts/lua")
    fs.mkdir(S .. "/plan/index.d")
    fs.write(S .. "/" .. SUBJECT, fs.read(SUBJECT))
    fs.write(S .. "/plan/index.yaml", "packets: []\n")
    local function git(...)
        return proc.run({ argv = { "git", "-C", S, "-c", "user.name=fixture", "-c", "user.email=fixture@invalid", ... }, timeout_ms = 60000 })
    end
    git("init", "-q")
    for p, body in pairs(base_files) do fs.write(S .. "/" .. p, body) end
    git("add", "-A")
    git("commit", "-qm", "base", "--no-verify")
    git("branch", "-q", "-f", "linux-next")
    for p, body in pairs(new_files) do fs.write(S .. "/" .. p, body) end
    local r = proc.run({ argv = { BIN, "script", "run", SUBJECT }, cwd = ROOT .. "/" .. S,
        env = { TILLANDSIAS_FRAGMENT_PARSE_BASE = "linux-next" }, timeout_ms = 120000 })
    local got = text.trim(r.stdout or "")
    if r.status == "exited" and r.code == 0 and got == want then
        out.line("ok:   " .. n .. " " .. name)
    else
        out.line("FAIL: " .. n .. " " .. name .. " — want " .. want .. ", got " .. got .. " rc=" .. tostring(r.code) .. " " .. (r.stderr or ""))
        failed[#failed + 1] = name
    end
end

run_arm(1, "UNDECLARED new packet is flagged", {}, {
    ["plan/index.d/new.yaml"] = "packets:\n  - packet_id: new-packet-no-tier\n    order: 9999-aaaa\n    status: ready\n    kind: bug\n",
}, "advisory:packet-tier-undeclared:1 (advisory)")

run_arm(2, "DECLARED notes-line is accepted", {}, {
    ["plan/index.d/new.yaml"] = "packets:\n  - packet_id: new-packet-with-tier\n    order: 9999-bbbb\n    status: ready\n    kind: bug\n    notes: |\n      size: S  implementer_tier: haiku\n",
}, "ok:packet-tier-declared:1")

run_arm(3, "EVENT-ONLY fragment is not a declaration", {}, {
    ["plan/index.d/event.yaml"] = "events:\n  - packet_id: some-existing-packet\n    event:\n      type: note\n      ts: \"2026-09-27T00:00:00Z\"\n      summary: just a note\n",
}, "ok:packet-tier-declared:0")

run_arm(4, "KNOWN packet_id in the base is not new", {
    ["plan/index.d/old.yaml"] = "packets:\n  - packet_id: old-packet\n    order: 9999-cccc\n",
}, {
    ["plan/index.d/new.yaml"] = "packets:\n  - packet_id: old-packet\n    order: 9999-cccc\n    status: ready\n",
}, "ok:packet-tier-declared:0")

if #failed > 0 then
    verdict.emit("violation:packet-tier-fixture:" .. #failed .. "-of-4-arms", 1)
end
verdict.emit("ok:packet-tier-fixture:4 arms", 0)
