-- @trace order:2250-44uy
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @env TILLANDSIAS_FLEET_RUN_TIMEOUT_MS
--
-- fleet-run.lua — the darwin/msys side of a second-regime request. Given a
-- gate step NUMBER and a REF (never a command), run exactly that one step of
-- that ref's tree on this host and answer one line:
--
--   regime:<platform>:step=<n>:rc=<rc>:result=<kind>:base=<sha|none>:sha=<tree>:verdict=<last verdict line>
--
-- result= is the verdict line's first word; a skip also ends with
-- skip:fleet-run:step=<n>:judged-nothing:... (rc 0), never ok:fleet-run.
-- base= is merge-base(<ref>, origin/linux-next) on this checkout, exported to the
-- step as TILLANDSIAS_GATE_DIFF_BASE(+_ROOT) so *-added deciders judge the diff.
--
-- The verdict is LAST because it may contain ':'.
--
-- No worktree (operator ruling 2026-10-11): target/work/fleet-run/<commit>/ is
-- its own repository (no remote), which fetches that one commit from this
-- checkout and checks it out, afresh on every run (not a cache). HEAD^{tree} must equal <ref>^{tree} AND the files
-- on disk must match it (git status clean), so nothing unstated is run. The
-- files come from git's own objects, not a tar (2259-fk3m): on native Windows
-- tar loses the exec bits and symlinks, and GNU tar reads C:/ as a host. The
-- step runs alone: the extracted tree, with every other step file removed, is
-- the --gate-steps root for that tree's own build.sh. On native Windows
-- build.sh cannot run a step (its setup wants gcc and builds the sidecar, and
-- the gate there runs in WSL, which is not msys), so the step's STEP_LUA or
-- STEP_SCRIPT is run directly, as the gate loop does: cwd the tree, and
-- STEP_SKIP_EXIT counts as rc 0. The loop's STEP_HOST_STATE retry and
-- metrics-leak check are not applied there. The plan binary is this
-- checkout's release build when the crates are identical, else one built from
-- the extracted tree into a shared target dir (one CARGO_TARGET_DIR, serial).
--
-- After the regime line: ok:fleet-run (rc 0) only when the step's rc is 0;
-- violation:fleet-run:step=<n>:rc=<rc> (rc 1) when it is not;
-- could-not-run:fleet-run:step-did-not-exit:<status> (rc 2) when it was killed.
--
-- Refusals (rc 2, one line, nothing run):
--   refused:fleet-run:usage | bad-step:<s> | bad-ref:<r> | unknown-ref:<r>
--   refused:fleet-run:no-step:<n> | ambiguous-step:<n>:<count>
--   refused:fleet-run:tree-mismatch:<want>:<got> | dirty-tree:<files> | could-not-run:fleet-run:<why>
--
-- Usage: tillandsias-plan script run scripts/lua/fleet-run.lua -- <step-number> <ref>

-- The extract is removed on every way out; only its log stays. A run that is
-- KILLED cannot do this; the next run sweeps an extract older than four hours
-- (a step's own deadline is one hour, so that is never a live one).
local D
local function drop() if D then proc.run({ argv = { "rm", "-rf", D }, timeout_ms = 300000 }) end end
local function refuse(what, rc)
    drop()
    verdict.emit("refused:fleet-run:" .. what, rc or 2)
end
local function cnr(why) drop(); verdict.emit("could-not-run:fleet-run:" .. why, 2) end

local A = {}
for i = 1, #arg do A[#A + 1] = arg[i] end
if #A ~= 2 then refuse("usage") end
local STEP, REF = A[1], A[2]
if not STEP:match("^%d+$") then refuse("bad-step:" .. STEP) end
-- A ref name only: no leading '-', no '..', no shell or revision syntax.
if REF:sub(1, 1) == "-" or REF:find("%.%.") or not REF:match("^[%w._/-]+$") then
    refuse("bad-ref:" .. REF)
end

local function run(argv, opts)
    opts = opts or {}
    opts.argv = argv
    opts.timeout_ms = opts.timeout_ms or 120000
    local r = proc.run(opts)
    return (r.status == "exited") and r.code or -1, text.trim(r.stdout or ""), r.stderr or ""
end

local fixture = require "common.fixture"
local BASH = fixture.posix_shell("/bin/bash")   -- Git's bash on native Windows
local WINDOWS = fixture.posix_shell() ~= "bash"
local EXE = WINDOWS and ".exe" or ""

local rc, ROOT = run({ "git", "rev-parse", "--show-toplevel" })
if rc ~= 0 or ROOT == "" then cnr("no-repo") end

local rc_u, uname = run({ "uname", "-s" })
local PLATFORM = "linux"
if uname == "Darwin" then PLATFORM = "darwin"
elseif WINDOWS then PLATFORM = "msys" end

-- Resolve the ref: as given, else origin/<ref> after fetching that one ref.
local function resolve(r)
    local c, s = run({ "git", "-C", ROOT, "rev-parse", "--verify", "--quiet", r .. "^{commit}" })
    if c == 0 and s ~= "" then return s end
    return nil
end
local COMMIT = resolve(REF)
if not COMMIT then
    run({ "git", "-C", ROOT, "fetch", "-q", "origin", REF }, { timeout_ms = 300000 })
    COMMIT = resolve("origin/" .. REF) or resolve("FETCH_HEAD")
end
if not COMMIT then refuse("unknown-ref:" .. REF) end
local _, TREE = run({ "git", "-C", ROOT, "rev-parse", COMMIT .. "^{tree}" })

local BASE = ROOT .. "/target/work/fleet-run"
-- A SHORT name (round 4): msys hits MAX_PATH on a fixture repo nested under a
-- 40-char dir (yolanda, step 750 "Filename too long"). 12 hex is unique here.
D = BASE .. "/" .. COMMIT:sub(1, 12)
local _, old = run({ "find", BASE, "-maxdepth", "1", "-type", "d", "-mmin", "+240" })
for _, l in ipairs(text.lines(old)) do
    local nm = l:match("/(%x+)$")
    if nm and (#nm == 12 or #nm == 40) then run({ "rm", "-rf", l }, { timeout_ms = 300000 }) end
end
run({ "rm", "-rf", D }, { timeout_ms = 300000 })
if run({ "mkdir", "-p", D }) ~= 0 then cnr("mkdir") end
local GENV = { GIT_AUTHOR_NAME = "fleet-run", GIT_AUTHOR_EMAIL = "fleet-run@localhost",
               GIT_COMMITTER_NAME = "fleet-run", GIT_COMMITTER_EMAIL = "fleet-run@localhost",
               GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_NOSYSTEM = "1" }
local function dgit(...)
    local argv = { "git", "-C", D, "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null" }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    return run(argv, { env = GENV, timeout_ms = 300000 })
end
if dgit("init", "-q") ~= 0 then cnr("git-init") end
-- No eol conversion (a core.autocrlf=true host); on Windows symlinks are text
-- files, as in an ordinary checkout there, and the nested path can be long.
dgit("config", "core.autocrlf", "false")
if WINDOWS then dgit("config", "core.symlinks", "false"); dgit("config", "core.longpaths", "true") end
-- The diff base (2250-44uy round 3): the gate freezes merge-base(HEAD,
-- origin/linux-next) and every *-added decider diffs against it. A depth=1
-- extract has no such commit, so each of them answered skip:...:no-base-ref,
-- judging nothing. The base is computed here, on this checkout's refs, and the
-- extract is fetched deep enough to hold it AND connect it to the ref (the
-- door keeps an inherited base only if it is an ancestor of HEAD).
local DIFF_BASE = ""
do
    local mc, mb = run({ "git", "-C", ROOT, "merge-base", COMMIT, "origin/linux-next" })
    if mc == 0 and mb:match("^%x+$") then DIFF_BASE = mb end
end
local DEPTH = "1"
if DIFF_BASE ~= "" then
    local _, n = run({ "git", "-C", ROOT, "rev-list", "--count", DIFF_BASE .. ".." .. COMMIT })
    DEPTH = tostring((tonumber(n) or 0) + 1)
end
if dgit("fetch", "-q", "--depth=" .. DEPTH, ROOT, COMMIT) ~= 0 then cnr("fetch") end
if DIFF_BASE ~= "" and dgit("merge-base", "--is-ancestor", DIFF_BASE, COMMIT) ~= 0 then
    cnr("diff-base-not-in-extract:" .. DIFF_BASE)
end
if dgit("checkout", "-q", "--detach", "FETCH_HEAD") ~= 0 then cnr("checkout") end
local _, GOT = dgit("rev-parse", "HEAD^{tree}")
if GOT ~= TREE then refuse("tree-mismatch:" .. TREE .. ":" .. GOT) end
local st_rc, dirty = dgit("status", "--porcelain")
if st_rc ~= 0 then cnr("git-status") end
if dirty ~= "" then refuse("dirty-tree:" .. #text.lines(dirty)) end
-- A checkout has target/ and a fresh extract does not; without it scratch.declare
-- drops <repo>/target as a base and refuses every T:scratch() (2266-acwj).
if run({ "mkdir", "-p", D .. "/target" }) ~= 0 then cnr("mkdir-target") end

-- Exactly one step file with this number.
-- (the runner's policy denies a shell, so the glob is git's pathspec)
local _, ls = dgit("ls-files", "--", "scripts/gate-steps.d/" .. STEP .. "-*.step")
local steps = {}
for _, l in ipairs(text.lines(ls)) do
    local b = l:match("^scripts/gate%-steps%.d/(.+)$")
    if b then steps[#steps + 1] = b end
end
if #steps == 0 then refuse("no-step:" .. STEP) end
if #steps > 1 then refuse("ambiguous-step:" .. STEP .. ":" .. #steps) end

-- The plan binary: reuse this checkout's when the crates match, else build.
local function subtree(c, p) local _, s = run({ "git", "-C", ROOT, "rev-parse", c .. ":" .. p }); return s end
-- One persistent target dir for fleet-run, for the plan build AND the step, so
-- a run does not rebuild the world. Never the checkout's own target/: cargo
-- would leave this ref's binaries there for the checkout to run (1807-shtg).
local CTD = BASE .. "/cargo-target"
local same = true
for _, p in ipairs({ "crates", "Cargo.lock", "Cargo.toml" }) do
    if subtree("HEAD", p) ~= subtree(COMMIT, p) then same = false end
end
local BIN = ROOT .. "/target/release/tillandsias-plan" .. EXE
if not same or run({ "test", "-x", BIN }) ~= 0 then
    local brc = run({ "cargo", "build", "-q", "--release", "-p", "tillandsias-plan" },
        { cwd = D, env = { CARGO_TARGET_DIR = CTD }, timeout_ms = 1800000 })
    if brc ~= 0 then cnr("plan-build:rc=" .. brc) end
    BIN = CTD .. "/release/tillandsias-plan" .. EXE
end

-- One step: the extracted tree IS the --gate-steps root (step paths resolve
-- against it), with every other step file removed AFTER the tree assertion
-- (not on Windows, where the step is run directly over the exact tree).
-- MODE (round 4). A ref whose build.sh has --gate-step runs ONE step over the
-- INTACT tree ("select"): a fixture that reads scripts/gate-steps.d/ sees every
-- step (746 and 764 were red with them deleted, green direct). An older ref
-- falls back to deleting the other step files ("alone"), named in the regime line.
local DREL = "target/work/fleet-run/" .. COMMIT:sub(1, 12)
local MODE = text.contains(fs.read(DREL .. "/build.sh") or "", "--gate-step)") and "select" or "alone"
if WINDOWS then MODE = "direct" end
if MODE == "alone" then
    local _, all = dgit("ls-files", "--", "scripts/gate-steps.d/*.step")
    for _, l in ipairs(text.lines(all)) do
        if l ~= "" and l ~= "scripts/gate-steps.d/" .. steps[1] then run({ "rm", "-f", D .. "/" .. l }) end
    end
end
local step_text = "\n" .. (fs.read(DREL .. "/scripts/gate-steps.d/" .. steps[1]) or "")
local function field(k) return step_text:match("\n" .. k .. '="([^"\n]*)"') or "" end
local desc = field("STEP_DESC")
local benv = { TILLANDSIAS_PLAN_BIN = BIN, TILLANDSIAS_SCRIPT_RUNNER_BIN = BIN, CARGO_TARGET_DIR = CTD }
-- Always set, so a base inherited from this host's own environment never rides in;
-- empty when this checkout has no origin/linux-next to measure from.
local _, DTOP = dgit("rev-parse", "--show-toplevel")
benv.TILLANDSIAS_GATE_DIFF_BASE = DIFF_BASE
benv.TILLANDSIAS_GATE_DIFF_BASE_ROOT = (DIFF_BASE ~= "") and DTOP or ""
local argv = { BASH, "./build.sh", "--gate-steps", D }
if MODE == "select" then argv[#argv + 1] = "--gate-step"; argv[#argv + 1] = STEP end
if WINDOWS then
    benv.TILLANDSIAS_SKIP_WSL2 = "1"   -- a step that runs build.sh must not re-exec into WSL
    local lua, script = field("STEP_LUA"), field("STEP_SCRIPT")
    if (lua == "") == (script == "") then cnr("step-names-not-exactly-one-of-STEP_LUA-STEP_SCRIPT") end
    if lua ~= "" then argv = { BIN, "script", "run", lua } else argv = { BASH, script } end
    desc = ""                          -- no door lines around the step's own output
end
local r = proc.run({ argv = argv, cwd = D, env = benv,
    timeout_ms = tonumber(env.get("TILLANDSIAS_FLEET_RUN_TIMEOUT_MS") or "") or 3600000 })
local src = (r.status == "exited") and r.code or -1
if WINDOWS and src ~= 0 and tostring(src) == (step_text:match('\nSTEP_SKIP_EXIT="?(%d+)') or "") then src = 0 end
local o = (r.stdout or "") .. "\n" .. (r.stderr or "")
fs.write("target/work/fleet-run/" .. COMMIT .. "-" .. STEP .. ".log", o)

-- The step's last verdict-shaped line (<word>:<word>...), read only AFTER the
-- step's own STEP_DESC line and before the door's next [build] line, so setup
-- and housekeeping lines never stand in for it.
-- STDOUT FIRST (round 4): a red step's door lines go to stderr, so a scan over
-- stdout..stderr ran past the step into the door's own note: lines and reported
-- note:gate-diff-base instead of the step's violation: (746, 764). stderr is read
-- only when stdout has no verdict at all. `PASS: ...` and `ok: <text>` count
-- (754, 756, 758 read "(no verdict line)").
local function verdict_shaped(t)
    return (t:match("^[%a][%w-]*:[%w]") or t:match("^[%a][%w-]*: %S")) and not t:match("^regime:")
end
local function scan(textblob, windowed)
    local found
    local started, done = (desc == "" or not windowed), false
    for _, l in ipairs(text.lines(textblob)) do
        local t = text.trim((l:gsub("\27%[[%d;]*m", "")))
        if done then
        elseif not started then
            if text.contains(t, desc) then started = true end
        elseif t:match("^%[build%]") then done = true -- the next door line ends the step
        elseif verdict_shaped(t) then found = t end
    end
    return found
end
local vline = scan(r.stdout or "", true)
-- Run directly (Windows), the verdict is on stdout; a stderr note is not one.
if not vline and not WINDOWS then vline = scan(r.stderr or "", false) end
vline = vline or "(no verdict line)"
-- A step that did not exit (killed, timed out, never started) has no result:
-- could-not-run, never ok: (calmecacpilli 2026-11-23).
local ended = r.status == "exited"
if not ended then vline = "could-not-run:step-did-not-exit:" .. tostring(r.status) end
drop()
-- result= is the verdict's kind (ok, skip, violation, advisory, ...), so a skip
-- is never read as evidence; base= is the diff base the step was given.
local kind = vline:match("^([%a][%w-]*):") or "none"
out.line("regime:" .. PLATFORM .. ":step=" .. STEP .. ":rc=" .. src .. ":result=" .. kind .. ":mode=" .. MODE
    .. ":base=" .. (DIFF_BASE ~= "" and DIFF_BASE or "none") .. ":sha=" .. TREE .. ":verdict=" .. vline)
if not ended then cnr("step-did-not-exit:" .. tostring(r.status)) end
if src ~= 0 then verdict.emit("violation:fleet-run:step=" .. STEP .. ":rc=" .. src
    .. ":log=target/work/fleet-run/" .. COMMIT .. "-" .. STEP .. ".log", 1) end
if kind == "skip" then verdict.emit("skip:fleet-run:step=" .. STEP .. ":judged-nothing:" .. vline, 0) end
verdict.ok("fleet-run", "step=" .. STEP .. " rc=" .. src .. " log=target/work/fleet-run/" .. COMMIT .. "-" .. STEP .. ".log")
