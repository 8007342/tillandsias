-- @env TILLANDSIAS_BOOTSTRAP_ALLOWLIST TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace spec:ci-release
-- @trace order:1443-xkwb
--
-- check-decider-retirement.lua — WHEN A BASH DECIDER RETIRES, by its own number.
-- (Ported from scripts/check-decider-retirement.sh, a shell-to-lua item;
-- history in `git log -- scripts/check-decider-retirement.sh`.)
--
-- The bash deciders (check-bash-dialect, check-sigpipe-verdict-pipelines-added,
-- check-jq-callsite-ratchet) were written for a bash corpus. As scripts move to
-- scripts/lua, the corpus each one scans shrinks toward the shell that MUST stay
-- shell: installers, the cargo bootstrap in build.sh, hook stubs, image
-- entrypoints (design §6.5, listed in scripts/portability/bootstrap-shell-allowlist.txt).
-- A decider whose whole population is that bootstrap set guards nothing that
-- can still regress into bash, and can retire. Each decider prints
-- `population=<n> bootstrap=<b>` on STDERR (its stdout verdict is an interface
-- and unchanged); this script runs them and applies the rule.
--
-- ADVISORY. It never fails a gate for a decider being live; it only answers.
--
-- Usage: tillandsias-plan script run scripts/lua/check-decider-retirement.lua [-- --root DIR]
--   Run it from this checkout: the deciders always come from the checkout the
--   current directory is in (the .sh used its own location).
--   --root DIR   the tree the deciders scan (default: this checkout). It may
--                lie outside the checkout; it is only probed through git,
--                test and the deciders, never read through fs.
--   TILLANDSIAS_BOOTSTRAP_ALLOWLIST   override the allowlist (fixtures); its
--                entries are then resolved against DIR instead of this checkout.
--   The plan binary that runs check-bash-dialect.lua is TILLANDSIAS_PLAN_BIN,
--   else TILLANDSIAS_SCRIPT_RUNNER_BIN, else <checkout>/target/release/tillandsias-plan,
--   else tillandsias-plan on PATH (the .sh used plan-binary-probe.sh).
--
-- Output, stdout, one line per decider then one summary line (unchanged):
--   retire:<decider> population=<n> bootstrap=<n>    population equals bootstrap
--   live:<decider> population=<n> bootstrap=<b>      it still guards migratable shell
--   blocked:decider-retirement:<decider>:<why>       it could not answer; NEVER retire
--   ok:decider-retirement:<live> live                  exit 0
--   blocked:decider-retirement:<n> could not answer    exit 1
--   blocked:decider-retirement:dangling-allowlist-entry:<path>   exit 1, nothing run
--   could-not-run:decider-retirement:<why>           exit 2
--
-- A decider whose population is EMPTY already refuses (1374-4u6i; the
-- jq ratchet spells it blocked:jq-ratchet-empty-population). That refusal is
-- carried through as blocked here: zero equals zero is not a retirement, it is
-- a scan that saw nothing.

local function cnr(why) verdict.emit("could-not-run:decider-retirement:" .. why, 2) end
local function ok(r) return r.status == "exited" and r.code == 0 end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local SELF_ROOT = ok(top) and text.trim(top.stdout or "") or ""
if SELF_ROOT == "" then cnr("not-in-a-checkout") end

-- An absolute path without resolving symlinks, as `cd DIR && pwd` gives.
local function absdir(d)
    if not ok(proc.run({ argv = { "test", "-d", d }, timeout_ms = 10000 })) then return nil end
    local r = proc.run({ argv = { "realpath", "-s", "--", d }, timeout_ms = 10000 })
    if not ok(r) then return nil end
    return text.trim(r.stdout or "")
end

local ROOT = SELF_ROOT
do
    local i = 1
    while i <= #arg do
        if arg[i] == "--root" then
            local d = arg[i + 1] or ""
            if d == "" then cnr("--root-needs-a-dir") end
            ROOT = absdir(d)
            if not ROOT or ROOT == "" then cnr("no-such-root:" .. d) end
            i = i + 2
        else
            cnr("unknown-argument:" .. tostring(arg[i]))
        end
    end
end

local ALLOWLIST, ENTRY_ROOT
local override = env.get("TILLANDSIAS_BOOTSTRAP_ALLOWLIST") or ""
if override ~= "" then
    ALLOWLIST = override; ENTRY_ROOT = ROOT
else
    ALLOWLIST = SELF_ROOT .. "/scripts/portability/bootstrap-shell-allowlist.txt"; ENTRY_ROOT = SELF_ROOT
end
if not ok(proc.run({ argv = { "test", "-f", ALLOWLIST }, timeout_ms = 10000 })) then
    cnr("no-allowlist:" .. ALLOWLIST)
end
local al = proc.run({ argv = { "cat", ALLOWLIST }, timeout_ms = 10000 })
if not ok(al) then cnr("no-allowlist:" .. ALLOWLIST) end

-- A dangling entry would count toward nothing and hide that the list is stale.
for _, l in ipairs(text.lines(al.stdout or "")) do
    local entry = l:match("^%s*(%S+)")
    if entry and entry:sub(1, 1) ~= "#" then
        if not ok(proc.run({ argv = { "test", "-e", ENTRY_ROOT .. "/" .. entry }, timeout_ms = 10000 })) then
            log.raw("  " .. ALLOWLIST .. " names " .. entry .. ", which does not exist under " .. ENTRY_ROOT)
            verdict.emit("blocked:decider-retirement:dangling-allowlist-entry:" .. entry, 1)
        end
    end
end

local PLAN = env.get("TILLANDSIAS_PLAN_BIN") or ""
if PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or "" end
if PLAN == "" then
    if fs.exists(SELF_ROOT .. "/target/release/tillandsias-plan") then
        PLAN = SELF_ROOT .. "/target/release/tillandsias-plan"
    else
        PLAN = "tillandsias-plan"
    end
end

-- run_decider(name) -> first stdout line, stderr. Each decider is driven
-- through its OWN root seam, never by editing it.
local function run_decider(name)
    local script = SELF_ROOT .. "/scripts/" .. name .. ".sh"
    if fs.exists(SELF_ROOT .. "/scripts/lua/" .. name .. ".lua") then
        script = SELF_ROOT .. "/scripts/lua/" .. name .. ".lua"
    end
    if not fs.exists(script) then
        return "could-not-run:decider-retirement:missing-decider:" .. name, ""
    end
    local e = { TILLANDSIAS_BOOTSTRAP_ALLOWLIST = ALLOWLIST }
    local r
    if name == "check-bash-dialect" then
        e.TILLANDSIAS_REPO_ROOT = ROOT
        r = proc.run({ argv = { PLAN, "script", "run", script }, cwd = ROOT, env = e, timeout_ms = 300000 })
        if r.status == "spawn_failed" then
            return "could-not-run:decider-retirement:no-script-runner:" .. name, ""
        end
    elseif name == "check-jq-callsite-ratchet" then
        r = proc.run({ argv = { "bash", script, "--root", ROOT }, cwd = SELF_ROOT, env = e, timeout_ms = 300000 })
    else
        e.TILLANDSIAS_SIGPIPE_ROOT = ROOT
        r = proc.run({ argv = { "bash", script }, cwd = SELF_ROOT, env = e, timeout_ms = 300000 })
    end
    return text.lines(r.stdout or "")[1] or "", r.stderr or ""
end

local live, unanswered = 0, 0
for _, d in ipairs({ "check-bash-dialect", "check-sigpipe-verdict-pipelines-added", "check-jq-callsite-ratchet" }) do
    local v, err = run_decider(d)
    local n, b
    for _, l in ipairs(text.lines(err)) do
        local pn, pb = l:match("^population=(%d+) bootstrap=(%d+)$")
        if pn then n, b = tonumber(pn), tonumber(pb) end
    end
    if v:find("scan-empty", 1, true) or v:find("empty-population", 1, true) or v:sub(1, 14) == "could-not-run:" then
        out.line("blocked:decider-retirement:" .. d .. ":" .. v)
        unanswered = unanswered + 1
    elseif not n then
        out.line("blocked:decider-retirement:" .. d .. ":no-population-line")
        unanswered = unanswered + 1
    elseif n > 0 and n == b then
        out.line("retire:" .. d .. " population=" .. n .. " bootstrap=" .. b)
    else
        out.line("live:" .. d .. " population=" .. n .. " bootstrap=" .. b)
        live = live + 1
    end
end

if unanswered > 0 then
    verdict.emit("blocked:decider-retirement:" .. unanswered .. " could not answer", 1)
end
verdict.emit("ok:decider-retirement:" .. live .. " live", 0)
