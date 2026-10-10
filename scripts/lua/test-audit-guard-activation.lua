-- @trace order:1570-25iq, order:599-4wzr, order:1087-h2z9, order:831-ezea
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-audit-guard-activation.lua — the auditor that proves every guard is
-- wired (scripts/lua/audit-guard-activation.lua, ported from the .sh by
-- 1570-25iq) had no fixture of its own. A Lua fixture on `script run`, not a
-- .sh: a new shell fixture would ADD an item to the shell-to-lua counter the
-- port is meant to burn down (the carried-obligation guard, 1577-g96z, read
-- this change as due for exactly that). Each arm exists because a weaker
-- auditor could pass it:
--
--   1 PARITY   on the live tree, the port and the pre-port .sh (resolved from
--              git, its ROOT line rewritten so it audits this tree from a
--              scratch copy — nothing is copied into the checkout) report the
--              same active/ORPHAN status for every guard and the same counts.
--   2 ORPHAN   NEGATIVE CONTROL: in a scratch repo an unreferenced check-*.sh
--              is reported ORPHAN, named on `orphans:`, and refused (exit 1).
--   3 WIRED    the same tree with the orphan removed passes (exit 0).
--   4 SYMLINK  the 1087-h2z9 shape: a guard named ONLY in a skill that
--              .claude/skills reaches through a SYMLINK onto the canonical
--              skills/ tree is active for the port (which never follows
--              links) and for the pinned .sh (find -L, which does).
--   5 EMPTY    831-ezea: a tree with no check-*.sh is refused, never ok.
--
-- Usage: tillandsias-plan script run scripts/lua/test-audit-guard-activation.lua [-- --plan <bin>]

local GUARD_REL = "scripts/lua/audit-guard-activation.lua"
if not fs.exists(GUARD_REL) then
    verdict.emit("violation:audit-guard-activation-fixture:no-auditor", 1, GUARD_REL .. " does not exist")
end
local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("audit-guard-activation-fixture", "no plan binary named (--plan, TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 120000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
local GUARD = ROOT .. "/" .. GUARD_REL
local REL = "target/plan-scratch/guard-activation-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
fs.mkdir(REL)

local passed, failed = {}, {}
local function check(name, cond, why)
    if cond then passed[#passed + 1] = name; out.line("ok:   " .. name)
    else failed[#failed + 1] = name; out.line("FAIL: " .. name .. " — " .. why) end
end
local function port_in(dir) -- -> rc, combined output
    local r = run({ PLAN, "script", "run", GUARD }, { cwd = dir, env = { TILLANDSIAS_REPO_ROOT = dir } })
    return (r.status == "exited" and r.code or -1), (r.stdout or "") .. (r.stderr or "")
end
local function status_set(s)
    local t = {}
    for _, l in ipairs(text.lines(s)) do
        local k, n = l:match("^(active):%s+(%S+)")
        if not k then k, n = l:match("^(ORPHAN):%s+(%S+)") end
        if k then t[#t + 1] = k .. " " .. n end
    end
    table.sort(t)
    return table.concat(t, "\n"), #t
end
local function line_of(s, re) for _, l in ipairs(text.lines(s)) do if text.is_match(l, re) then return l end end return nil end

-- The .sh this was ported from: the deletion commit's parent once the port
-- has landed, else the last commit that touched it.
local function pinned_sha()
    local d = text.trim(run({ "git", "log", "-n", "1", "--format=%H", "--diff-filter=D", "--", "scripts/audit-guard-activation.sh" }).stdout or "")
    if d ~= "" then return d .. "^" end
    local m = text.trim(run({ "git", "log", "-n", "1", "--format=%H", "--", "scripts/audit-guard-activation.sh" }).stdout or "")
    if m ~= "" then return m end
    return nil
end
local SHA = pinned_sha()
local PINNED -- the pinned .sh text, or nil
if SHA then
    local r = run({ "git", "show", SHA .. ":scripts/audit-guard-activation.sh" })
    if r.status == "exited" and r.code == 0 then PINNED = r.stdout end
end

-- ── 1. PARITY on the live tree ─────────────────────────────────────────────
if PINNED then
    local rooted = PINNED:gsub("\nROOT=[^\n]*", '\nROOT="$AUDIT_ROOT"', 1)
    fs.write(REL .. "/pinned-rooted.sh", rooted)
    local sh = run({ "bash", W .. "/pinned-rooted.sh" }, { env = { AUDIT_ROOT = ROOT } })
    local sh_out = (sh.stdout or "") .. (sh.stderr or "")
    local _, lua_out = port_in(ROOT)
    local sh_set, n = status_set(sh_out)
    local lua_set = status_set(lua_out)
    local shv = line_of(sh_out, "^guard%-activation: ") or line_of(sh_out, [[^guard-activation: ]]) or ""
    local luav = line_of(lua_out, [[^(ok|violation):guard-activation:]]) or ""
    local sh_counts = shv:gsub("^guard%-activation: ", "")
    local lua_counts = luav:gsub("^[a-z]+:guard%-activation:", "")
    check("PARITY: same status for each guard and same counts as the pinned .sh",
        n >= 10 and sh_set == lua_set and sh_counts == lua_counts,
        "guards=" .. n .. " sets-equal=" .. tostring(sh_set == lua_set) .. " .sh=[" .. shv .. "] port=[" .. luav .. "]")
else
    check("PARITY (skip: the pre-port .sh is unreachable in this clone's history)", true, "")
end

-- A scratch repo: build.sh names check-wired.sh; skills/demo/SKILL.md names
-- check-skill.sh; .claude/skills/demo is a SYMLINK onto skills/demo.
local function scratch(name, with_orphan)
    local rel = REL .. "/" .. name
    local d = ROOT .. "/" .. rel
    for _, sub in ipairs({ "", "/scripts", "/skills", "/skills/demo", "/.claude", "/.claude/skills" }) do fs.mkdir(rel .. sub) end
    fs.write(rel .. "/scripts/check-wired.sh", "#!/usr/bin/env bash\necho ok\n")
    fs.write(rel .. "/scripts/check-skill.sh", "#!/usr/bin/env bash\necho ok\n")
    fs.write(rel .. "/build.sh", "#!/usr/bin/env bash\nbash scripts/check-wired.sh\n")
    fs.write(rel .. "/skills/demo/SKILL.md", "---\nname: demo\n---\nRun `bash scripts/check-skill.sh`.\n")
    fs.write(rel .. "/.gitignore", ".cache/\n")
    run({ "ln", "-s", "../../skills/demo", d .. "/.claude/skills/demo" })
    if with_orphan then fs.write(rel .. "/scripts/check-orphan.sh", "#!/usr/bin/env bash\necho ok\n") end
    run({ "git", "init", "-q" }, { cwd = d })
    run({ "git", "-c", "user.email=f@f", "-c", "user.name=f", "add", "-A" }, { cwd = d })
    run({ "git", "-c", "user.email=f@f", "-c", "user.name=f", "-c", "commit.gpgsign=false", "commit", "-qm", "seed" }, { cwd = d })
    return d
end
local function has(s, line) for _, l in ipairs(text.lines(s)) do if l == line then return true end end return false end

-- ── 2. NEGATIVE CONTROL: an unreferenced guard refuses ──────────────────────
local rc, o = port_in(scratch("orphan", true))
check("ORPHAN: an unreferenced check-orphan.sh is named and the verdict refuses (exit 1)",
    rc == 1 and has(o, "orphans: check-orphan.sh") and line_of(o, [[^ORPHAN:\s+check-orphan\.sh]]) ~= nil
        and has(o, "violation:guard-activation:population=3 total=3 active=2 orphan=1 verdict=orphans-found"),
    "rc=" .. rc .. " out=[" .. o .. "]")

-- ── 3 + 4. WIRED, and the symlink-farm shape judged the same by both ───────
local wired = scratch("wired", false)
rc, o = port_in(wired)
check("WIRED: every referenced guard is active and the verdict passes",
    rc == 0 and has(o, "ok:guard-activation:population=2 total=2 active=2 orphan=0 verdict=ok"),
    "rc=" .. rc .. " out=[" .. o .. "]")
local port_active = line_of(o, [[^active:\s+check-skill\.sh]]) ~= nil
if PINNED then
    fs.write(REL .. "/wired/scripts/audit-guard-activation.sh", PINNED)
    local sh = run({ "bash", wired .. "/scripts/audit-guard-activation.sh" }, { cwd = wired })
    local sh_active = line_of((sh.stdout or ""), [[^active:\s+check-skill\.sh]]) ~= nil
    check("SYMLINK: a guard named only in a symlinked skill is active for the port (no link-following) and for the pinned .sh (find -L)",
        port_active and sh_active, "port=" .. tostring(port_active) .. " pinned-sh=" .. tostring(sh_active))
else
    check("SYMLINK: a guard named only in a symlinked skill is active for the port (pinned .sh unreachable; comparison skipped)",
        port_active, "port did not report check-skill.sh active")
end

-- ── 5. an empty population is a refusal (831-ezea) ─────────────────────────
local erel = REL .. "/empty"
fs.mkdir(erel); fs.mkdir(erel .. "/scripts")
fs.write(erel .. "/build.sh", "#!/usr/bin/env bash\n")
fs.write(erel .. "/.gitignore", ".cache/\n")
local ed = ROOT .. "/" .. erel
run({ "git", "init", "-q" }, { cwd = ed })
run({ "git", "-c", "user.email=f@f", "-c", "user.name=f", "add", "-A" }, { cwd = ed })
run({ "git", "-c", "user.email=f@f", "-c", "user.name=f", "-c", "commit.gpgsign=false", "commit", "-qm", "seed" }, { cwd = ed })
rc, o = port_in(ed)
check("EMPTY: no check-*.sh is refused as unavailable, never reported ok",
    rc == 1 and o:find("verdict=unavailable:no-guards-enumerated", 1, true) ~= nil, "rc=" .. rc .. " out=[" .. o .. "]")

run({ "rm", "-rf", W })

if #failed > 0 then
    verdict.emit("violation:audit-guard-activation-fixture:" .. #failed .. ":of:" .. (#passed + #failed), 1,
        "failed arms: " .. table.concat(failed, "; "))
end
verdict.ok("audit-guard-activation-fixture", #passed)
