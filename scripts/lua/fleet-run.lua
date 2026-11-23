-- @trace order:2250-44uy
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- fleet-run.lua — the darwin/msys side of a second-regime request. Given a
-- gate step NUMBER and a REF (never a command), run exactly that one step of
-- that ref's tree on this host and answer one line:
--
--   regime:<platform>:step=<n>:rc=<rc>:sha=<tree>:verdict=<last verdict line>
--
-- The verdict is LAST because it may contain ':'.
--
-- No worktree (operator ruling 2026-10-11): `git archive <ref>` is extracted
-- into target/work/fleet-run/<commit>/, given its own `git init` + one commit,
-- and that commit's tree must equal <ref>^{tree} (tracked-but-ignored files
-- are added with -f, so a .gitignore cannot drop them silently). The step is
-- copied alone into a scratch --gate-steps root and run by the extracted
-- tree's own build.sh. The plan binary is this checkout's release build when
-- the crates are identical, else one built from the extracted tree into a
-- shared target dir (one CARGO_TARGET_DIR, serial).
--
-- Refusals (rc 2, one line, nothing run):
--   refused:fleet-run:usage | bad-step:<s> | bad-ref:<r> | unknown-ref:<r>
--   refused:fleet-run:no-step:<n> | ambiguous-step:<n>:<count>
--   refused:fleet-run:tree-mismatch:<want>:<got> | could-not-run:fleet-run:<why>
--
-- Usage: tillandsias-plan script run scripts/lua/fleet-run.lua -- <step-number> <ref>

local function refuse(what, rc)
    verdict.emit("refused:fleet-run:" .. what, rc or 2)
end
local function cnr(why) verdict.emit("could-not-run:fleet-run:" .. why, 2) end

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

local rc, ROOT = run({ "git", "rev-parse", "--show-toplevel" })
if rc ~= 0 or ROOT == "" then cnr("no-repo") end

local rc_u, uname = run({ "uname", "-s" })
local PLATFORM = "linux"
if uname == "Darwin" then PLATFORM = "darwin"
elseif uname:match("^MINGW") or uname:match("^MSYS") or uname:match("^CYGWIN") then PLATFORM = "msys" end

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
local D = BASE .. "/" .. COMMIT
run({ "rm", "-rf", D })
if run({ "mkdir", "-p", D }) ~= 0 then cnr("mkdir") end
local TAR = BASE .. "/" .. COMMIT .. ".tar"
if run({ "git", "-C", ROOT, "archive", "-o", TAR, COMMIT }, { timeout_ms = 300000 }) ~= 0 then cnr("archive") end
local xrc = run({ "tar", "-xf", TAR, "-C", D }, { timeout_ms = 300000 })
run({ "rm", "-f", TAR })
if xrc ~= 0 then cnr("extract") end

local GENV = { GIT_AUTHOR_NAME = "fleet-run", GIT_AUTHOR_EMAIL = "fleet-run@localhost",
               GIT_COMMITTER_NAME = "fleet-run", GIT_COMMITTER_EMAIL = "fleet-run@localhost",
               GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_NOSYSTEM = "1" }
local function dgit(...)
    local argv = { "git", "-C", D, "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null" }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    return run(argv, { env = GENV, timeout_ms = 300000 })
end
if dgit("init", "-q") ~= 0 then cnr("git-init") end
if dgit("add", "-A", "-f") ~= 0 then cnr("git-add") end
if dgit("commit", "-q", "--no-verify", "-m", "fleet-run " .. COMMIT) ~= 0 then cnr("git-commit") end
local _, GOT = dgit("rev-parse", "HEAD^{tree}")
if GOT ~= TREE then refuse("tree-mismatch:" .. TREE .. ":" .. GOT) end

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
local same = true
for _, p in ipairs({ "crates", "Cargo.lock", "Cargo.toml" }) do
    if subtree("HEAD", p) ~= subtree(COMMIT, p) then same = false end
end
local BIN = ROOT .. "/target/release/tillandsias-plan"
if not same or run({ "test", "-x", BIN }) ~= 0 then
    local CTD = BASE .. "/cargo-target"
    local brc = run({ "cargo", "build", "-q", "--release", "-p", "tillandsias-plan" },
        { cwd = D, env = { CARGO_TARGET_DIR = CTD }, timeout_ms = 1800000 })
    if brc ~= 0 then cnr("plan-build:rc=" .. brc) end
    BIN = CTD .. "/release/tillandsias-plan"
end

-- One step: the extracted tree IS the --gate-steps root (step paths resolve
-- against it), with every other step file removed AFTER the tree assertion.
local _, all = dgit("ls-files", "--", "scripts/gate-steps.d/*.step")
for _, l in ipairs(text.lines(all)) do
    if l ~= "" and l ~= "scripts/gate-steps.d/" .. steps[1] then run({ "rm", "-f", D .. "/" .. l }) end
end
local desc = (fs.read("target/work/fleet-run/" .. COMMIT .. "/scripts/gate-steps.d/" .. steps[1]) or "")
    :match('\nSTEP_DESC="([^"\n]*)"') or ""
local r = proc.run({ argv = { "/bin/bash", "./build.sh", "--gate-steps", D }, cwd = D, timeout_ms = 3600000,
    env = { TILLANDSIAS_PLAN_BIN = BIN, TILLANDSIAS_SCRIPT_RUNNER_BIN = BIN } })
local src = (r.status == "exited") and r.code or -1
local o = (r.stdout or "") .. "\n" .. (r.stderr or "")
fs.write("target/work/fleet-run/" .. COMMIT .. ".log", o)

-- The step's last verdict-shaped line (<word>:<word>...), read only AFTER the
-- step's own STEP_DESC line and before the door's next [build] line, so setup
-- and housekeeping lines never stand in for it.
local vline = "(no verdict line)"
local started, done = (desc == ""), false
for _, l in ipairs(text.lines(o)) do
    local t = text.trim((l:gsub("\27%[[%d;]*m", "")))
    if done then
    elseif not started then
        if text.contains(t, desc) then started = true end
    elseif t:match("^%[build%]") then done = true -- the next door line ends the step
    elseif t:match("^[%a][%w-]*:[%w]") and not t:match("^regime:") then vline = t end
end
out.line("regime:" .. PLATFORM .. ":step=" .. STEP .. ":rc=" .. src .. ":sha=" .. TREE .. ":verdict=" .. vline)
verdict.ok("fleet-run", "step=" .. STEP .. " rc=" .. src .. " log=target/work/fleet-run/" .. COMMIT .. ".log")
