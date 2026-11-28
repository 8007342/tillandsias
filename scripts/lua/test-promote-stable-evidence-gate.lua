-- @env PATH HOME
-- inputs: plan/index.yaml plan/loop_status.md scripts/diagnose-macos-enclave.sh scripts/lua/check-promote-gate.lua scripts/promote-stable.sh scripts/release-website-marker.sh VERSION lib/lua/common/ crates/tillandsias-plan/ plan/index.d/ plan/issues/ plan/loop_status.d/
-- @trace spec:ci-release, order:864-8tqv, order:1061-zd83, order:2296-pn45, order:2404-grd6
--
-- test-promote-stable-evidence-gate.lua — pin promote-stable.sh's gates. Ported from
-- test-promote-stable-evidence-gate.sh (2404-grd6); its 39 arms in its order, plus
-- seven arms closing branches neither covered (9c, 9d, 12b, P4b, Z1b, Z1c, Z1d).
--
-- WHY. The evidence gate once could not see the e2e skill's own reports (it wanted "smoke",
-- PASS and the version on ONE line; the skill puts "smoke" in the filename). The fix widened
-- where the identity may come from, never what counts as a verdict: a correctly named file
-- that says FAIL is still refused (arm 3). order 888 (unfiled in the ledger) made the gate PER-PLATFORM and stopped it
-- reading ledgers as reports; 2296-pn45 added the record gate beside it.
--
-- SAFETY (864-8tqv). Every gate arm runs --dry-run in a SCRATCH copy of the root, with
-- TRIPWIRES first on PATH: `git` records and fails on any invocation, `gh` serves reads and
-- records any write verb. After each arm the violation log must be EMPTY. The MUTATION
-- CONTROL proves the tripwire is real: the current script with only its dry-run guard
-- defeated must trip it. The three step-3 arms (1061-zd83) and the deploy arm run PAST
-- --dry-run, against stubs that absorb gh and git writes, so nothing outward-facing moves.
-- GH_*, GITHUB_TOKEN and TILLANDSIAS_* are stripped from every child; the one TILLANDSIAS_
-- name a child sees is the plan-binary STUB the record gate is asked through.
--
-- NOT PORTED: the .sh's opt-in PROMOTE_DRYRUN_ONLINE arm (off by default) exec'd the REAL gh
-- against GitHub. A fixture here never reaches the real gh, so that arm stays with the .sh's
-- history; it never ran in a gate.
--
-- Usage: tillandsias-plan script run scripts/lua/test-promote-stable-evidence-gate.lua
-- Verdict: ok:promote-stable-evidence-gate:<n> arms | violation:promote-stable-evidence-gate:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("promote-stable-evidence-gate")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local REAL_GIT = fixture.which("git")
if not REAL_GIT then T:refuse("no-git", "the step-3 stubs pass reads through to git") end
local SUBJECT = "scripts/promote-stable.sh"
local SUBJECT_TEXT = fs.read(SUBJECT)
if not SUBJECT_TEXT then T:refuse("subject-absent", SUBJECT) end

local VER = "v0.4.260817.1"
local W = T:scratch("work")
local BIN = W.abs .. "/bin"
fs.mkdir(W.rel .. "/bin")
local VIOL_REL, VIOL = W.rel .. "/violations.log", W.abs .. "/violations.log"
local UNSET = { "TILLANDSIAS_*", "GH_*", "GITHUB_*", "PG_*", "DEPLOY_*", "PROMOTE_*", "XDG_STATE_HOME" }
local BASE_PATH = env.get("PATH") or "/usr/bin:/bin"

local function exe(dir, name, body) fs.write(dir.rel .. "/" .. name, body); T:must{ "chmod", "+x", dir.abs .. "/" .. name } end
local WB = { rel = W.rel .. "/bin", abs = BIN }

-- TRIPWIRES, not stubs: a write is recorded AND refused, so a leak fails loudly.
exe(WB, "gh", [[#!/usr/bin/env bash
case "$1 ${2:-}" in
    "release view") [ -z "${STUB_NO_RELEASE:-}" ] || exit 1; printf '%s\n' "deadbeef"; exit 0 ;;
    "repo view")   printf '%s\n' "8007342/tillandsias"; exit 0 ;;
    "release edit") echo "MUTATION gh $*" >> "$VIOLATIONS"; exit 1 ;;
esac
if [ "$1" = "api" ]; then
    case " $* " in
        *" -X PATCH "*|*" -X POST "*|*" -X DELETE "*) echo "MUTATION gh $*" >> "$VIOLATIONS"; exit 1 ;;
    esac
    case " $* " in
        *"releases/latest"*) printf '%s\n' "v0.0.0.0"; exit 0 ;;
        *"releases/tags/"*)  printf '%s\n' "12345";    exit 0 ;;
    esac
    exit 0
fi
exit 0
]])
exe(WB, "git", [[#!/usr/bin/env bash
echo "MUTATION git $*" >> "$VIOLATIONS"
exit 1
]])
-- The record gate (check-promote-gate.lua) has its own fixture; here its ANSWER is stubbed.
exe(WB, "plan-stub", [[#!/usr/bin/env bash
echo "$*" >> "${PG_ARGV:-/dev/null}"
echo "${PG_LINE-ok:promote-gate:v0.4.260817.1:linux=pass,darwin=pass,windows=pass:queue=idle}"; exit "${PG_RC:-0}"
]])
local PLAN_STUB = BIN .. "/plan-stub"

local function merge(a, b) local o = {} for k, v in pairs(a or {}) do o[k] = v end for k, v in pairs(b or {}) do o[k] = v end return o end

-- A fresh scratch root holding a copy of the subject (or a given body) and the deploy stub.
local function fresh_root(body)
    local d = T:scratch("root")
    fs.mkdir(d.rel .. "/scripts"); fs.mkdir(d.rel .. "/plan/issues")
    fs.write(d.rel .. "/scripts/promote-stable.sh", body or SUBJECT_TEXT)
    -- Step 4's helper (1798-khw6) is a stub; DEPLOY_LOG records any call (2066-obsv: none).
    exe({ rel = d.rel .. "/scripts", abs = d.abs .. "/scripts" }, "advance-deploy-ref.sh", [[#!/usr/bin/env bash
echo "DEPLOY-REF $*" >> "${DEPLOY_LOG:-/dev/null}"
if [ "${DEPLOY_STUB_RC:-0}" -ne 0 ]; then echo "refused:deploy-ref-push-refused:$1"; exit 1; fi
echo "verified:deploy-ref:$1:tree=0000000000000000000000000000000000000000"
]])
    return d
end
local function seed(d, plat, ver, verdict)
    fs.write(d.rel .. "/plan/issues/smoke-e2e-findings-" .. ver .. "-2026-08-17-" .. plat .. ".md",
        "# curl-install e2e — " .. ver .. " on " .. plat .. " — findings\n\n## Run 2026-08-17T17:58Z — **"
        .. (verdict or "PASS") .. "** (tag " .. ver .. ", build commit 0bba6525f)\n")
end
local function seed_all(d, ver) seed(d, "linux", ver); seed(d, "macos", ver); seed(d, "windows", ver) end

-- One dry-run through the tripwires. Returns rc, stdout, stderr, the violation log.
local function promote(d, args, extra)
    fs.write(VIOL_REL, "")
    local argv = { SH, d.abs .. "/scripts/promote-stable.sh" }
    for _, a in ipairs(args or { VER, "--dry-run" }) do argv[#argv + 1] = a end
    argv.env = merge({ PATH = BIN .. ":" .. BASE_PATH, VIOLATIONS = VIOL, TILLANDSIAS_PLAN_BIN = PLAN_STUB,
        GIT_CEILING_DIRECTORIES = W.abs }, extra)
    argv.env_unset, argv.cwd, argv.timeout_ms = UNSET, d.abs, 60000
    local r = T:run(argv)
    return r.code, r.stdout or "", r.stderr or "", fs.read(VIOL_REL) or ""
end
local function verdict_line(out)
    local last = ""
    for _, l in ipairs(text.lines(out)) do
        if l:match("^promoted:") or l:match("^would%-promote:") or l:match("^would%-demote:")
            or l:match("^demoted:") or l:match("^refused:") then last = l end
    end
    return last
end
-- Two assertions per arm: the verdict line matches, and NOTHING was mutated.
local function case(name, d, want, args, extra)
    local rc, o, _, v = promote(d, args, extra)
    local last = verdict_line(o)
    T:arm(name, last:find(want) ~= nil and v == "",
        "verdict='" .. last .. "' rc=" .. tostring(rc) .. " expected " .. want .. (v ~= "" and (" MUTATED: " .. v) or ""))
end

-- 1 THE REGRESSION CASE: the exact shape the e2e skill writes.
local d = fresh_root(); seed_all(d, VER)
case("1 real e2e-skill evidence shape (was BROKEN)", d, "^would%-promote:")
-- 2 No evidence anywhere.
d = fresh_root(); fs.write(d.rel .. "/plan/issues/unrelated.md", "nothing relevant here\n")
case("2 no evidence at all", d, "^refused:no%-evidence:")
-- 3 THE ONE THAT KEEPS THE FIX HONEST: right filename, FAIL verdict.
d = fresh_root(); seed(d, "linux", VER); seed(d, "macos", VER); seed(d, "windows", VER, "FAIL")
case("3 correctly named file but FAIL verdict", d, "^refused:no%-evidence:.*missing=windows")
-- 4 A PASS for a different version.
d = fresh_root()
fs.write(d.rel .. "/plan/issues/smoke-e2e-findings-v0.4.260810.1-2026-08-10.md", "## Run 2026-08-10 — **PASS** (tag v0.4.260810.1)\n")
case("4 PASS exists but for a different version", d, "^refused:no%-evidence:")
-- 5 The legacy single-line shape, inside a file that names itself a report.
d = fresh_root()
for _, p in ipairs{ "linux", "macos", "windows" } do
    fs.write(d.rel .. "/plan/issues/smoke-e2e-findings-legacy-" .. p .. ".md", "curl-install e2e smoke PASS for 0.4.260817.1 on " .. p .. "\n")
end
case("5 legacy single-line evidence still accepted", d, "^would%-promote:")
-- 6 Dot-escaping: v0X4X260817X1 must not match.
d = fresh_root(); seed(d, "linux", VER); seed(d, "macos", VER)
fs.write(d.rel .. "/plan/issues/smoke-e2e-findings-windows-2026-08-17.md", "# e2e findings on windows\n\n## Run — **PASS** (tag v0X4X260817X1)\n")
case("6 regex dots do not match arbitrary chars", d, "^refused:no%-evidence:.*missing=windows")

-- 7-9 The dry-run's own grammar, and the demote path (864-mk2p).
d = fresh_root(); seed_all(d, VER)
case("7 flags parse in either order", d, "^would%-promote:", { VER, "--dry-run", "--force" })
case("8 bad tag refused before any gh call", d, "^refused:bad%-tag:", { "not-a-tag", "--dry-run" })
case("9 demote dry-run names the restore", d, "^would%-demote:v0%.4%.260817%.1:latest%-would%-be:v0%.4%.260810%.1",
    { "demote", VER, "--to", "v0.4.260810.1", "--dry-run" })
case("9b demote without --to is refused", d, "^refused:missing%-target:", { "demote", VER, "--dry-run" })
-- 9c (M01) an unknown flag is refused by name, never ignored.
case("9c an unknown --flag is refused", d, "^refused:bad%-tag:%-%-bogus$", { VER, "--bogus", "--dry-run" })
-- 9d (M06) a tag with no GitHub release is refused, and nothing is promoted.
local rc9d, o9d, e9d, v9d = promote(d, nil, { STUB_NO_RELEASE = "1" })
T:arm("9d a tag gh cannot see as a release is refused", rc9d == 1 and verdict_line(o9d) == "refused:no-release:" .. VER and v9d == ""
    and text.contains(e9d, "the tag has no GitHub release"), "rc=" .. tostring(rc9d) .. " verdict='" .. verdict_line(o9d) .. "' err=" .. e9d:sub(1, 200))

-- 10 THE HEADLINE NEGATIVE CONTROL: one platform must NOT satisfy three.
for _, only in ipairs{ "linux", "macos", "windows" } do
    d = fresh_root(); seed(d, only, VER)
    case("10 ONLY " .. only .. " passed -> refused, names the other two", d, "^refused:no%-evidence:.*missing=")
end
-- 11 Two of three is still not three.
d = fresh_root(); seed(d, "linux", VER); seed(d, "macos", VER)
case("11 two of three platforms -> refused naming windows", d, "^refused:no%-evidence:.*missing=windows")
-- 12 THE JUNK CONTROL: a ledger is not a report.
d = fresh_root(); fs.mkdir(d.rel .. "/plan/loop_status.d")
fs.write(d.rel .. "/plan/index.yaml", "packets:\n  - packet_id: describes-the-gate-defect\n    summary: |\n      the smoke evidence gate reported PASS for "
    .. VER .. " on linux, macos and\n      windows without checking any of them — see the incident\n")
fs.write(d.rel .. "/plan/loop_status.d/20260823t215305z-x-lenovinha.md", "## Cycle\nfreshness audit: scripts/run-smoke-e2e.sh litmus suite PASS "
    .. VER .. " linux macos windows\n")
case("12 ledger co-occurrence is NOT evidence (index.yaml + loop_status)", d, "^refused:no%-evidence:.*missing=linux,macos,windows")
-- 12b (M08) a ledger file NAMED like a report is still a ledger: report identity alone does not admit it.
d = fresh_root(); seed(d, "linux", VER); seed(d, "macos", VER); fs.mkdir(d.rel .. "/plan/index.d")
fs.write(d.rel .. "/plan/index.d/20260823t000000z-smoke-e2e-windows.yaml", "# smoke e2e windows\nsummary: windows smoke PASS " .. VER .. "\n")
case("12b a ledger file named smoke is not a report", d, "^refused:no%-evidence:.*missing=windows")
-- 13 A work-queue log line is not a report (it says FAIL while saying PASS).
d = fresh_root(); seed(d, "linux", VER); seed(d, "macos", VER)
fs.write(d.rel .. "/plan/issues/windows-next-work-queue-2026-07.md", "- 2026-08-16T06:05Z FULL curl-install smoke " .. VER
    .. " (windows): run PASS\n  end-to-end — but promotion verdict for the tag UNCHANGED (morning FAIL).\n")
case("13 work-queue log line is not a report (says FAIL, said PASS)", d, "^refused:no%-evidence:.*missing=windows")
-- 14 PLATFORM DETECTION IS SCOPED to the filename and first heading.
d = fresh_root(); seed(d, "macos", VER)
fs.write(d.rel .. "/plan/issues/smoke-e2e-findings-" .. VER .. "-2026-08-17-windows.md", "# curl-install e2e — " .. VER
    .. " on Windows — findings\n\n## Run 2026-08-17T17:58Z — **PASS** (tag " .. VER .. ")\nStep 4 (the --opencode forge lane) is not run here — that lane is Linux/Podman\nper the skill's §0.1.\n")
case("14 body mentioning Linux does not make a windows report linux evidence", d, "^refused:no%-evidence:.*missing=linux")
-- 15 --force STILL OVERRIDES.
d = fresh_root(); seed(d, "windows", VER)
case("15 --force overrides incomplete per-platform evidence", d, "^would%-promote:", { VER, "--dry-run", "--force" })
-- 16 ...and the override is LOUD: it names the missing platforms.
local _, _, e16 = promote(d, { VER, "--dry-run", "--force" })
T:arm("16 --force warning names what was overridden", text.contains(e16, "missing platform(s): linux,macos"), e16:sub(1, 400))
-- 17 A PASS that disclaims promotion counts, and warns loudly.
d = fresh_root(); seed_all(d, VER)
fs.write(d.rel .. "/plan/issues/smoke-e2e-findings-" .. VER .. "-2026-08-17-windows.md", "# smoke — " .. VER
    .. " — windows FULL lane re-run — PASS (run-scoped; does NOT clear promotion)\n\n## Run 2026-08-17T17:58Z — **PASS** (tag " .. VER .. ")\n")
local _, o17, e17 = promote(d)
T:arm("17 PASS-but-disclaimed counts, and warns loudly", verdict_line(o17):find("^would%-promote:") ~= nil and text.contains(e17, "disclaiming"),
    "out=" .. o17:sub(1, 200) .. " err=" .. e17:sub(1, 300))
-- 18 NEGATIVE CONTROL for 17: clean evidence does not warn.
d = fresh_root(); seed_all(d, VER)
local _, _, e18 = promote(d)
T:arm("18 clean evidence does not warn", not text.contains(e18, "disclaiming"), e18:sub(1, 300))
-- 19 The required set is configurable: linux alone is satisfied by linux.
d = fresh_root(); seed(d, "linux", VER)
local _, o19 = promote(d, nil, { TILLANDSIAS_REQUIRED_PLATFORMS = "linux" })
T:arm("19 REQUIRED_PLATFORMS=linux is satisfied by linux", verdict_line(o19):find("^would%-promote:") ~= nil, verdict_line(o19))
-- 20 The accept path NAMES the evidence per platform, with the caveat, and cites no retracted packet.
d = fresh_root(); seed_all(d, VER)
local _, _, e20 = promote(d)
local named = text.contains(e20, "preconditions held") and not text.contains(e20, "889-bx99")
for _, p in ipairs{ "linux", "macos", "windows" } do
    local hit = false
    for _, l in ipairs(text.lines(e20)) do if l:match("^  " .. p .. "%s+plan/issues/.*" .. p) then hit = true end end
    named = named and hit
end
T:arm("20 accept path names the evidence per platform", named, (e20:gsub("\n", "|")):sub(1, 500))
-- 21 NEGATIVE CONTROL for 20: a refusal prints no evidence list.
d = fresh_root(); seed(d, "linux", VER)
local _, _, e21 = promote(d)
T:arm("21 refusal does not print an evidence list", not text.contains(e21, "Evidence satisfying this promotion"), e21:sub(1, 300))

-- MUTATION CONTROL: the current script with ONLY its dry-run guard defeated must trip the wire.
local GUARD, DEFEATED = "--dry-run)  DRY_RUN=1 ;;", "--dry-run)  DRY_RUN=0 ;;"
local s0, e0 = SUBJECT_TEXT:find(GUARD, 1, true)
if not s0 then
    T:arm("MUTATION CONTROL: guard-defeated script trips the wire", false,
        "could not defeat the guard; the arg-parser line moved, so this control is not testing what it claims")
else
    d = fresh_root(SUBJECT_TEXT:sub(1, s0 - 1) .. DEFEATED .. SUBJECT_TEXT:sub(e0 + 1)); seed_all(d, VER)
    local _, _, _, v = promote(d)
    T:arm("MUTATION CONTROL: guard-defeated script trips the wire", v ~= "",
        "guard-defeated script mutated NOTHING; the tripwire cannot see writes, so every '0 mutations' above is vacuous")
end

-- 1061-zd83: STEP 3 IS VERIFIED, NOT ASSUMED. These run PAST --dry-run against stubs that
-- absorb writes, so "the push failed" and "the tag landed elsewhere" are observable.
local function stub_dir(push_rc, remote_sha, unresolvable)
    local s = T:scratch("stub")
    exe(s, "gh", "#!/usr/bin/env bash\ncase \"$*\" in\n"
        .. "  \"repo view\"*)            echo \"8007342/tillandsias\" ;;\n"
        .. "  *\"release view\"*targetCommitish*) echo \"main\" ;;\n"
        .. "  *\"release view\"*)        exit 0 ;;\n  *\"release edit\"*)        exit 0 ;;\n"
        .. "  *\"api\"*releases/latest*) echo \"" .. VER .. "\" ;;\n  *) exit 0 ;;\nesac\n")
    exe(s, "git", "#!/usr/bin/env bash\nargs=\"$*\"\ncase \"$args\" in\n"
        .. "  *\"push origin refs/tags/stable\"*) exit " .. push_rc .. " ;;\n"
        .. "  *\"ls-remote origin refs/tags/stable^{}\"*) " .. (remote_sha ~= "" and ("printf '%s\\trefs/tags/stable^{}\\n' " .. remote_sha .. "; ") or "")
        .. "exit 0 ;;\n"
        .. (unresolvable and "  *\"rev-parse --verify --quiet\"*) exit 1 ;;\n" or
            ("  *\"rev-parse --verify --quiet refs/tags/\"*\"^{commit}\"*) echo \"1111111111111111111111111111111111111111\"; exit 0 ;;\n"
            .. "  *\"rev-parse --verify --quiet main^{commit}\"*) echo \"2222222222222222222222222222222222222222\"; exit 0 ;;\n"))
        .. "  *\"tag -f -a stable\"*) exit 0 ;;\n  *\"fetch\"*) exit 0 ;;\n"
        .. "  *) exec \"" .. REAL_GIT .. "\" \"$@\" ;;\nesac\n")
    return s.abs
end
local function run_promote(push_rc, remote_sha, extra, unresolvable)
    d = fresh_root(); seed_all(d, VER)
    local s = stub_dir(push_rc, remote_sha, unresolvable)
    local argv = { SH, d.abs .. "/scripts/promote-stable.sh", VER }
    argv.env = merge({ PATH = s .. ":" .. BASE_PATH, TILLANDSIAS_PLAN_BIN = PLAN_STUB, GIT_CEILING_DIRECTORIES = W.abs,
        XDG_STATE_HOME = W.abs .. "/state" }, extra)
    argv.env_unset, argv.cwd, argv.timeout_ms = UNSET, d.abs, 60000
    local r = T:run(argv)
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local function has_line(s, pat) for _, l in ipairs(text.lines(s)) do if l:find(pat) then return true end end return false end
local rc1, o1 = run_promote(1, "")
T:arm("Z1 tag push failure is not a promotion", rc1 ~= 0 and not has_line(o1, "^promoted:"), "rc=" .. tostring(rc1) .. " " .. o1:sub(-300))
local _, o2 = run_promote(0, "9999999999999999999999999999999999999999")
T:arm("Z2 origin tag disagreeing is refused by name", has_line(o2, "^refused:stable%-tag%-not%-moved:"), o2:sub(-300))
local rc3, o3 = run_promote(0, "1111111111111111111111111111111111111111")
-- Z1b (M23) the push fails while origin happens to show the tag: still a push failure, by name.
local _, o1b = run_promote(1, "1111111111111111111111111111111111111111")
T:arm("Z1b a failed push is refused as a push failure even when origin shows the tag",
    has_line(o1b, "^refused:stable%-tag%-push%-refused:") and not has_line(o1b, "^promoted:"), o1b:sub(-300))
-- Z1c (M24) the push succeeds but origin cannot be read back: unverified, not "disagreed".
local _, o1c = run_promote(0, "")
T:arm("Z1c an unreadable origin is refused as unverified", has_line(o1c, "^refused:stable%-tag%-unverified:")
    and not has_line(o1c, "^promoted:"), o1c:sub(-300))
-- Z1d (M26) neither the tag nor targetCommitish resolves to a commit: refused before any tag moves.
local _, o1d = run_promote(0, "", nil, true)
T:arm("Z1d an unresolvable release commit is refused", has_line(o1d, "^refused:promote%-commit%-unresolvable:")
    and not has_line(o1d, "^promoted:"), o1d:sub(-300))
T:arm("Z3 a landed tag still reports a promotion", rc3 == 0 and has_line(o3, "^verified:stable%-tag:1111111111111111111111111111111111111111")
    and has_line(o3, "^promoted:" .. VER:gsub("%.", "%%.")), "rc=" .. tostring(rc3) .. " " .. o3:sub(-300))

-- 2066-obsv: A PROMOTION NEVER DEPLOYS THE OBSERVATORIUM.
local DLOG_REL = W.rel .. "/deploy.log"
fs.write(DLOG_REL, "")
local rc4, o4 = run_promote(0, "1111111111111111111111111111111111111111", { DEPLOY_LOG = W.abs .. "/deploy.log" })
local dl = fs.read(DLOG_REL) or ""
T:arm("O1 a promotion never moves deploy/observatorium", rc4 == 0 and dl == "" and not text.contains(o4, "deploy-ref")
    and has_line(o4, "^promoted:" .. VER:gsub("%.", "%%.")), "rc=" .. tostring(rc4) .. " log=" .. dl .. " " .. o4:sub(-200))
T:arm("O2 promote-stable.sh names no deploy ref", not text.contains(SUBJECT_TEXT, "deploy/observatorium")
    and not text.contains(SUBJECT_TEXT, "advance-deploy-ref"), "the subject still names a deploy ref")

-- 2296-pn45: THE RECORD GATE IS ASKED, AND ITS NO IS A NO.
d = fresh_root(); seed_all(d, VER)
local PGA_REL = W.rel .. "/pg.argv"
fs.write(PGA_REL, "")
local PG = { PG_ARGV = W.abs .. "/pg.argv" }
local VQ = VER:gsub("%.", "%%.")
case("P1 the record gate's ok promotes", d, "^would%-promote:" .. VQ .. "$", nil, PG)
case("P2 an unmeasured platform is passed on by name", d, "^would%-promote:" .. VQ .. "$",
    { VER, "--dry-run", "--allow-unmeasured", "darwin", "--approval", "smoke-row" }, PG)
T:arm("P3 the gate is asked for this tag and the named platform",
    has_line(fs.read(PGA_REL) or "", "check%-promote%-gate%.lua %-%- " .. VQ .. " %-%-allow%-unmeasured darwin %-%-approval smoke%-row$"),
    (fs.read(PGA_REL) or ""):gsub("\n", ";"))
case("P4 its refusal refuses", d, "^refused:promote%-gate:" .. VQ .. "$", nil,
    merge(PG, { PG_RC = "1", PG_LINE = "refused:promote-gate:" .. VER .. ":linux=missing queue=idle" }))
case("P4b a non-zero rc with an ok line refuses", d, "^refused:promote%-gate:" .. VQ .. "$", nil,
    merge(PG, { PG_RC = "1", PG_LINE = "ok:promote-gate:" .. VER .. ":linux=pass,darwin=pass,windows=pass:queue=idle" }))
case("P5 an ok for another tag refuses", d, "^refused:promote%-gate:" .. VQ .. "$", nil, merge(PG, { PG_RC = "0", PG_LINE = "ok:promote-gate:v9.9.9.9:x" }))
case("P6 silence with rc 0 refuses", d, "^refused:promote%-gate:" .. VQ .. "$", nil, merge(PG, { PG_RC = "0", PG_LINE = "" }))
case("P7 could-not-run refuses", d, "^refused:promote%-gate:" .. VQ .. "$", nil,
    merge(PG, { PG_RC = "3", PG_LINE = "could-not-run:promote-gate:trunk-head-unreadable" }))
case("P8 no plan binary refuses", d, "^refused:promote%-gate:" .. VQ .. "$", nil, merge(PG, { TILLANDSIAS_PLAN_BIN = BIN .. "/absent" }))
case("P9 --force overrides it, as it does the reports", d, "^would%-promote:" .. VQ .. "$", { VER, "--dry-run", "--force" },
    merge(PG, { PG_RC = "1", PG_LINE = "refused:promote-gate:" .. VER .. ":queue=gating" }))

-- M05 (2404-grd6): THE DEMOTE VERIFY-AFTER. A live demote whose writes "succeed" while
-- /releases/latest stays sticky must refuse; without the verify read it printed demoted:.
-- The writes go only to a scratch-local gh/git that log them; nothing reaches a network.
local DB = { rel = W.rel .. "/dbin", abs = W.abs .. "/dbin" }
fs.mkdir(DB.rel)
local DLOG_D_REL, DLOG_D = W.rel .. "/demote.log", W.abs .. "/demote.log"
exe(DB, "gh", [[#!/usr/bin/env bash
echo "gh $*" >> "$DEMOTE_LOG"
case "$1 ${2:-}" in
    "release view") printf '%s\n' "deadbeef"; exit 0 ;;
    "repo view")   printf '%s\n' "8007342/tillandsias"; exit 0 ;;
    "release edit") exit 0 ;;
esac
case " $* " in
    *"releases/latest"*) printf '%s\n' "$LATEST_AFTER"; exit 0 ;;
    *"releases/tags/"*)  printf '%s\n' "12345"; exit 0 ;;
esac
exit 0
]])
exe(DB, "git", [[#!/usr/bin/env bash
echo "git $*" >> "$DEMOTE_LOG"
exit 0
]])
local TGT = "v0.4.260810.1"
local function demote_live(latest_after)
    fs.write(DLOG_D_REL, "")
    local dd = fresh_root()
    local r = T:run{ SH, dd.abs .. "/scripts/promote-stable.sh", "demote", VER, "--to", TGT,
        env = { PATH = DB.abs .. ":" .. BASE_PATH, DEMOTE_LOG = DLOG_D, LATEST_AFTER = latest_after,
            TILLANDSIAS_PLAN_BIN = PLAN_STUB, GIT_CEILING_DIRECTORIES = W.abs },
        env_unset = UNSET, cwd = dd.abs, timeout_ms = 60000 }
    return r.code, verdict_line(r.stdout or ""), fs.read(DLOG_D_REL) or ""
end
local rcs, vs, ls = demote_live(VER)
T:arm("M05a a sticky latest after a live demote is refused", rcs ~= 0
    and vs:find("^refused:demote%-verify%-failed:" .. VQ .. "$") ~= nil and text.contains(ls, "releases/latest"),
    "rc=" .. tostring(rcs) .. " verdict='" .. vs .. "'")
local rcv, vv = demote_live(TGT)
T:arm("M05b a latest that moved verifies the demote", rcv == 0
    and vv:find("^demoted:" .. VQ .. ":latest%-now:" .. TGT:gsub("%.", "%%.") .. "$") ~= nil,
    "rc=" .. tostring(rcv) .. " verdict='" .. vv .. "'")

T:finish()
