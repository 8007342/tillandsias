-- @trace order:1443-qwpj, spec:meta-orchestration
-- scripts/verify-closure.sh over a scratch ledger and a scratch repo holding the script the
-- closures name. The arms that matter are the ones that must NOT accept: a wrong count, a
-- wrong rc, an empty placeholder, prose with no command (5), a delegate's "met" (6), a prose
-- threshold beside a command that exits 0 (7, the 1437-gbwi misreport), a skip (8).
-- Port of test-verify-closure.sh. The verdict line is the one its callers match.
local fixture = require "common.fixture"
local T = fixture.new("verify-closure")
local plan = fixture.plan_binary()
if plan == "" then T:skip("no-plan-binary") end
local d = T:scratch()
fs.mkdir(d.rel .. "/repo/scripts")
fs.mkdir(d.rel .. "/repo/plan/index.d")
fs.write(d.rel .. "/repo/scripts/x.sh", '#!/usr/bin/env bash\n. "$(dirname "$0")/x.conf"\necho "some preamble"\n'
    .. 'printf \'%s\\n\' "$X_LINE"\nexit "$X_RC"\n')
fs.write(d.rel .. "/repo/plan/index.yaml", "packets: []\n")
local function row(order, closure)
    fs.write(d.rel .. "/repo/plan/index.d/20260928t000000z-" .. order .. "-fixture.yaml",
        "packets:\n  - packet_id: row-" .. order .. "\n    order: " .. order .. "\n    status: ready\n"
        .. "    kind: bug\n    priority: p2\n    desired_release: v0.5\n    pickup_role: any\n"
        .. "    title: a fixture row\n    verifiable_closure: |\n      " .. closure:gsub("\n", "\n      ") .. "\n")
end
row("1-aaaa", "bash scripts/x.sh prints ok:x:3/3 and exits 0, where the three\narms are described here in prose. PRE-FIX RESULT: FAILS.")
row("1-bbbb", "bash scripts/x.sh prints hit:<key12> and exits 0.")
row("1-cccc", "The operator confirms the tray looks right after a restart.")
row("1-dddd", "bash scripts/x.sh exits 0 with every existing ok line unchanged, and\nthe timing record carries duration_ms under 20,000 on this host.")
row("1-eeee", "bash scripts/x.sh exits 0 with the four arms above.")

-- What x.sh prints and exits is a file, not an environment the verifier might not pass on.
local function vc(line, rc, order, ...)
    fs.write(d.rel .. "/repo/scripts/x.conf", "X_LINE='" .. line .. "'\nX_RC=" .. rc .. "\n")
    local argv = { fixture.posix_shell(), "scripts/verify-closure.sh", order }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    for _, a in ipairs({ "--index", d.abs .. "/repo/plan/index.yaml", "--root", d.abs .. "/repo" }) do argv[#argv + 1] = a end
    argv.env = { TILLANDSIAS_PLAN_BIN = plan }
    local r = T:run(argv)
    return text.trim(r.stdout or ""), r.code
end
local function is(o, rc, want, want_rc) return o == want and rc == want_rc end
local function show(o, rc) return "rc=" .. tostring(rc) .. " [" .. o .. "]" end

local o, rc = vc("ok:x:3/3", 0, "1-aaaa")
T:arm("1 the expected line and rc 0 is ok", is(o, rc, "ok:closure:1-aaaa:ok:x:3/3", 0), show(o, rc))
o, rc = vc("ok:x:2/3", 0, "1-aaaa")
T:arm("2 the wrong count is unmet, naming what was measured",
    is(o, rc, "unmet:closure:1-aaaa:expected=ok:x:3/3 measured=ok:x:2/3", 1), show(o, rc))
o, rc = vc("ok:x:3/3", 3, "1-aaaa")
T:arm("3 the right line with the wrong rc is unmet", is(o, rc, "unmet:closure:1-aaaa:rc=3", 1), show(o, rc))
o, rc = vc("hit:0123456789ab", 0, "1-bbbb")
local o2, rc2 = vc("hit:", 0, "1-bbbb")
T:arm("4 a placeholder matches a token, and not an empty one",
    is(o, rc, "ok:closure:1-bbbb:hit:0123456789ab", 0) and rc2 == 1, show(o, rc) .. show(o2, rc2))
o, rc = vc("ok:x:3/3", 0, "1-cccc")
T:arm("5 CONTROL: prose with no command is unscoreable", is(o, rc, "unscoreable:closure:1-cccc:no-command-grammar", 2), show(o, rc))
o, rc = vc("ok:x:2/3", 0, "1-aaaa", "--claim", "met")
T:arm("6 CONTROL: --claim met does not turn unmet into ok", rc == 1 and o:find("unmet:closure:1-aaaa:", 1, true) == 1, show(o, rc))
o, rc = vc("anything", 0, "1-dddd")
T:arm("7 rc 0 beside a prose threshold is uncovered-criterion",
    rc == 2 and o:find("unscoreable:closure:1-dddd:uncovered-criterion:", 1, true) == 1, show(o, rc))
o, rc = vc("skip:x:no-plan-binary — build one", 0, "1-eeee")
o2, rc2 = vc("ok:x:4/4", 0, "1-eeee")
T:arm("8 an rc-only closure: a skip is unmet, a pass is ok",
    is(o, rc, "unmet:closure:1-eeee:skipped:skip:x:no-plan-binary", 1) and is(o2, rc2, "ok:closure:1-eeee:rc=0", 0),
    show(o, rc) .. show(o2, rc2))
T:finish{ ok = function(n) return "ok:verify-closure:" .. n .. "/8" end }
