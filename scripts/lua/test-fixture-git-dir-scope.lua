-- @trace order:1443-fpck, order:2355-ncuh, spec:command-policies
--
-- test-fixture-git-dir-scope.lua — under regime=fixture a fixture cannot write into the
-- real checkout's git dir or outside its declared scope, so the 1442-22d2 shape (a fixture
-- minting a full-scope gate stamp there, adopted by four relay lands) is unconstructible.
-- Every arm runs in SCRATCH repositories. Ported from the .sh (2355-ncuh).
--
--   1 regime=fixture + scope: Lua fs.write and fs.mkdir into the git dir raise
--     refused:policy:fixture-writes-outside-scope (why, remedy) and write nothing; so does
--     a write outside the scope
--   2 proc.run of gate-stamp.sh write, and git update-ref, against that repo: policy_denied
--   3 run-litmus-test.sh exports the regime and scope: a step that writes its checkout's
--     gate stamp goes RED naming the rule, and the bytes are restored
--   4 NEGATIVE: the same writes inside the scope succeed, regime=gate is unaffected, and a
--     step writing only its own scratch passes
--   0 the real checkout's tillandsias-gate-* files are byte-identical at exit
--
-- Verdict: ok:fixture-git-dir-scope:<n> arms | violation:fixture-git-dir-scope:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("fixture-git-dir-scope")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end

local function real_digest()
    return T:run{ SH, "-s", cwd = ROOT, stdin = [[
for d in "$(git rev-parse --absolute-git-dir)" "$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"; do
    for f in "$d"/tillandsias-gate-*; do [ -f "$f" ] && printf '%s %s\n' "$(cksum <"$f")" "$f"; done
done | sort -u
]] }.stdout or ""
end
local before = real_digest()

local W = T:scratch()
fs.write(W.rel .. "/gitconfig", "[user]\n\tname = t\n\temail = t@example.invalid\n")
local S, Srel = W.abs .. "/repo", W.rel .. "/repo"
fs.mkdir(Srel .. "/scratch/inner")
T:must{ "git", "init", "-q", S }
T:must{ "git", "init", "-q", S .. "/scratch/inner" }

-- As run-litmus-test.sh does: the regime, the scope, and the git dirs it protects.
local FIXTURE = { TILLANDSIAS_POLICY_REGIME = "fixture", TILLANDSIAS_FIXTURE_SCOPE = S .. "/scratch", TILLANDSIAS_FIXTURE_GIT_DIRS = S .. "/.git" }
local function run(argv, cwd, extra)
    local e = { TILLANDSIAS_POLICY_AUDIT_LOG = W.abs .. "/audit.jsonl", GIT_CONFIG_GLOBAL = W.abs .. "/gitconfig", GIT_CONFIG_NOSYSTEM = "1" }
    for k, v in pairs(extra) do e[k] = v end
    argv.cwd, argv.env, argv.env_unset, argv.timeout_ms = cwd, e, { "TILLANDSIAS_*", "GIT_*", "CARGO_TARGET_DIR" }, 150000
    local r = T:run(argv)
    return (r.stdout or "") .. (r.stderr or "")
end
local function lua(code, cwd, e) return run({ PLAN, "lua", "-e", code }, cwd, e) end
local function call(fn, args) return lua("print(pcall(" .. fn .. ", " .. args .. "))", S, FIXTURE) end
local function has(o, s) return o:find(s, 1, true) ~= nil end
local RULE = "refused:policy:fixture-writes-outside-scope"

local o = call("fs.write", "'" .. S .. "/.git/tillandsias-gate-stamp', 'x'")
T:arm("1 fs.write into the git dir is refused with why and remedy, and writes nothing", has(o, RULE) and ("\n" .. o):find("\nwhy: [^\n]*real checkout")
    and ("\n" .. o):find("\nremedy: ", 1, true) and not fs.exists(Srel .. "/.git/tillandsias-gate-stamp"), o)
o = call("fs.write", "'" .. S .. "/outside.txt', 'x'")
T:arm("1 a write outside the declared scope is refused too", o:find("outside the fixture.s declared scope") and not fs.exists(Srel .. "/outside.txt"), o)
o = call("fs.mkdir", "'" .. S .. "/.git/hooks-planted'")
T:arm("1 fs.mkdir under the git dir is refused", has(o, "fs.mkdir: " .. RULE) and not fs.exists(Srel .. "/.git/hooks-planted"), o)

local function denied(cwd, argv, e)
    return text.trim(lua("local r = proc.run{argv={" .. argv .. "}, cwd='" .. cwd .. "'}; print(r.status, r.rule_id or '-')", cwd, e))
end
-- The inner program names the shell itself: it is the argv the rule must match.
local STAMP = ",'write','--scope','full','--dispatch','check'"
local BASH = "'bash'"
o = denied(S, BASH .. ",'scripts/gate-stamp.sh'" .. STAMP, FIXTURE)
T:arm("2 proc.run of gate-stamp.sh write against the real repo is policy_denied", o == "policy_denied\tfixture-gate-stamp-write", o)
o = denied(S, "'git','update-ref','refs/heads/x','HEAD'", FIXTURE)
T:arm("2 git update-ref against the real repo is policy_denied", o == "policy_denied\tfixture-writes-outside-scope", o)

o = call("fs.write", "'" .. S .. "/scratch/out.txt', 'y'")
T:arm("4 the same fs.write inside the scope succeeds", o:match("^[^\n]*") == "true\ttrue" and fs.exists(Srel .. "/scratch/out.txt")
    and fs.read(Srel .. "/scratch/out.txt") == "y", o)
o = denied(S .. "/scratch/inner", BASH .. ",'" .. ROOT .. "/scripts/gate-stamp.sh'" .. STAMP, FIXTURE)
T:arm("4 gate-stamp.sh write in a scratch repo INSIDE the scope is not policy-denied", o ~= "" and not o:find("^policy_denied"), o)
o = denied(S, "'git','update-ref','refs/heads/x','HEAD'", { TILLANDSIAS_POLICY_REGIME = "gate" })
T:arm("4 regime=gate is unaffected", o ~= "" and not o:find("^policy_denied"), o)

-- 3: the litmus runner, copied into a scratch project. The probe's name is built, so
-- check-litmus-pin-claims does not read it as a claim on a real litmus test.
local LIT = "litmus"
local P, Prel = W.abs .. "/project", W.rel .. "/project"
fs.mkdir(Prel .. "/lt")
T:must{ "git", "init", "-q", P }
T:must{ "cp", "-R", ROOT .. "/scripts", P .. "/scripts" }
fs.write(Prel .. "/bindings.yaml", "version: '1.0'\ndescription: fixture for 1443-fpck\nspecs:\n- spec_id: spec-traceability\n  status: active\n  "
    .. LIT .. "_tests:\n  - " .. LIT .. ":fpck-probe\n  coverage_ratio: 100\n  last_verified: '2026-09-28'\n")
local function probe(command)
    fs.write(Prel .. "/lt/" .. LIT .. "-fpck-probe.yaml", "name: " .. LIT .. ":fpck-probe\nspec: spec-traceability\nphase: pre-build\nseverity: high\n"
        .. "size: instant\ndescription: >\n  probe for 1443-fpck\ncritical_path:\n  - step: \"probe\"\n    command: " .. json.encode(command)
        .. "\n    timeout_ms: 20000\n    expected_behavior: \"probe-done\"\n")
    local r = run({ SH, P .. "/scripts/run-litmus-test.sh", "spec-traceability", "--phase", "pre-build", "--size", "instant", "--compact" }, P,
        { TILLANDSIAS_PLAN_BIN = PLAN, TILLANDSIAS_LITMUS_BINDINGS = P .. "/bindings.yaml", TILLANDSIAS_LITMUS_TESTS_DIR = P .. "/lt" })
    return (r:gsub("\27%[[0-9;]*m", ""))
end
local REAL = Prel .. "/.git/tillandsias-gate-stamp"
local MINT = 'printf minted > "$(git rev-parse --absolute-git-dir)/tillandsias-gate-stamp"; echo probe-done'
o = probe(MINT)
T:arm("3 a litmus step minting its checkout's stamp goes RED naming the rule, and the file is removed",
    has(o, "refused:policy:fixture-gate-stamp-write") and has(o, "Status: [FAIL]") and not fs.exists(REAL), o:sub(-1200))
T:must{ SH, "-s", "--", P .. "/.git/tillandsias-gate-stamp", stdin = "printf 'earned\\n' > \"$1\"\n" }
local function earned() return fs.exists(REAL) and fs.read(REAL) == "earned\n" end
o = probe(MINT)
T:arm("3 a pre-existing stamp the step overwrote is restored", has(o, "refused:policy:fixture-gate-stamp-write") and earned(), o:sub(-1200))
o = probe('t=$(mktemp -d); git init -q "$t"; printf x > "$t/.git/tillandsias-gate-stamp"; rm -rf "$t"; [ "$TILLANDSIAS_POLICY_REGIME" = fixture ] && echo probe-done')
T:arm("4 a step writing only its own scratch passes, and sees regime=fixture", has(o, "Status: [PASS]") and earned(), o:sub(-1200))

local after = real_digest()
T:arm("0 the real checkout's gate files are byte-identical at exit", before == after, before .. " -> " .. after)
T:finish()
