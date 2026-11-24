-- @env PATH HOME
-- @trace order:1115-srfr, order:2285-haa6, spec:ci-release
--
-- test-cycle-claims-report.lua — fixture for scripts/report-held-claims.sh,
-- ported from the .sh of the same name (2285-haa6). The .sh asked the LIVE
-- ledger which host holds a claim, so its held arm ran only when someone did;
-- here a stub plan binary answers, and no arm reads or writes the real ledger.
--
--   1 NONE     a host holding nothing gets an AFFIRMATIVE ok line, never silence
--   2 HELD     a holding host is warned, each packet named with its release
--              command, and another host's claim is not counted
--   3 NO-BIN   no plan binary is a NAMED skip, never a quiet pass (965-sxec)
--   4 ADVISORY exit 0 in every one of those states
--   5 CALL     the binary is asked exactly `expire-claims --list-live`
--   6 MUTANT   without the host filter arm 2's count is wrong
--
-- Usage: tillandsias-plan script run scripts/lua/test-cycle-claims-report.lua
-- Verdict: ok:cycle-claims-report:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("cycle-claims-report")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local S = T:scratch()
fs.mkdir(S.rel .. "/scripts")
for _, f in ipairs{ "report-held-claims.sh", "plan-binary-probe.sh", "agent-identity.sh" } do
    fs.write(S.rel .. "/scripts/" .. f, fs.read("scripts/" .. f))
end
fs.write(S.rel .. "/plan", table.concat({
    "#!/bin/sh",
    'case "$1" in capabilities) echo append-event; echo script; exit 0 ;; esac',
    'echo "$*" >> "' .. S.abs .. '/calls"',
    [[printf 'live-claim\t1115-aaaa\tfixture-held-packet\tfixturehost\t2026-01-01T00:00:00Z\n']],
    [[printf 'live-claim\t1115-cccc\tfixture-second-packet\tfixturehost\t2026-01-01T00:00:00Z\n']],
    [[printf 'live-claim\t1115-dddd\tother-packet\totherhost\t2026-01-01T00:00:00Z\n']],
    [[printf 'expire-candidate\t1115-eeee\tstale-packet\tfixturehost\t2026-01-01T00:00:00Z\n']], "" }, "\n"))
fs.write(S.rel .. "/calls", "")
T:must{ "chmod", "+x", S.abs .. "/plan", S.abs .. "/scripts/agent-identity.sh" }

local function report(script, host, bin, path)
    local r = proc.run{ argv = { SH, "-s", "--", S.abs .. "/scripts/" .. script, host, bin }, cwd = S.abs, timeout_ms = 60000,
        env = { PATH = path or env.get("PATH"), HOME = S.abs },
        stdin = 'unset CARGO_TARGET_DIR\nTILLANDSIAS_PLAN_BIN="$3" exec bash "$1" "$2" </dev/null\n' }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local function starts(o, p) return o:sub(1, #p) == p end
local has = text.contains
local BIN = S.abs .. "/plan"

local c1, o1 = report("report-held-claims.sh", "nobody-1115", BIN)
T:arm("1 NONE a host holding nothing prints the affirmative ok line", starts(o1, "ok:cycle-claims-released:0 held by nobody-1115"), o1)
local c2, o2 = report("report-held-claims.sh", "fixturehost", BIN)
T:arm("2 HELD the host's two claims are counted, named, and given their release command",
    starts(o2, "warn:cycle-claims-held:2 by fixturehost") and has(o2, "1115-aaaa  fixture-held-packet") and has(o2, "1115-cccc  fixture-second-packet")
    and has(o2, "tillandsias-plan set-field 1115-aaaa status ready --reason") and not has(o2, "other-packet") and not has(o2, "stale-packet"), o2)
local c3, o3 = report("report-held-claims.sh", "somehost", S.abs .. "/does-not-exist", "/usr/bin:/bin")
T:arm("3 NO-BIN an absent plan binary is a named skip, not a quiet zero", starts(o3, "skip:cycle-claims:no-plan-binary"), o3)
T:arm("4 ADVISORY exit 0 in every reachable state", c1 == 0 and c2 == 0 and c3 == 0, table.concat({ tostring(c1), tostring(c2), tostring(c3) }, ","))
local bad_call = nil
for _, l in ipairs(text.lines(fs.read(S.rel .. "/calls"))) do if l ~= "expire-claims --list-live" then bad_call = l end end
T:arm("5 CALL the binary is asked only for the live list", not bad_call and has(fs.read(S.rel .. "/calls"), "expire-claims --list-live"), tostring(bad_call))
local mut, n = fs.read("scripts/report-held-claims.sh"):gsub(' && %$4==h', "", 1)
fs.write(S.rel .. "/scripts/mutant.sh", mut)
local _, o6 = report("mutant.sh", "fixturehost", BIN)
T:arm("6 MUTANT without the host filter the count is wrong", n == 1 and starts(o6, "warn:cycle-claims-held:3 by"), "n=" .. n .. " " .. o6)
T:finish()
