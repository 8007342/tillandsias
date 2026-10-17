-- @trace order:1264-s4id
-- @env PATH TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-push-capability.lua — images/default/lib-push-capability.sh, sourced
-- by bash exactly as the forge's lib-common.sh sources it.
-- REPOSITORY LEVEL, from the mirror's verdict (stub `git` serving
-- `ls-remote origin 'refs/tillandsias/upstream-auth/*'`):
--   1 CAN-PUSH   authorized                  -> push_state=can-push, not loud
--   2 READ-ONLY  denied/permission           -> push_state=read-only, LOUD,
--                "this token is read only for <repo>" and what still works;
--                a SUPPORTED state, not an error (the function returns 0)
--   3 REVOKED    denied/unauthenticated      -> push_state=revoked, LOUD
--   4 SSO        denied/sso                  -> sso-required, LOUD
--   5 NO-CRED    no-credential               -> no-credential, LOUD
--   6 LOCAL      local-only                  -> local-only, not loud
--   7 PENDING    no ref yet                  -> unknown(probe-pending)
--   8 UNREACH    ls-remote fails             -> unknown(mirror-unreachable)
--   9 NEWEST     two verdicts: the larger epoch wins
-- BRANCH LEVEL, asked of the project's own discipline (`tillandsias-plan
-- discipline check-ref`, the installed pre-push hook's decision):
--  10 FREE      no seed                     -> push_branch=free
--  11 REFUSED   a seed protecting `main`, on main -> refused, "move away from
--               main", the seed's own remedy
--  12 FOLLOWS   the SAME detector with the seed's default branch changed to
--               `trunk`: main is now ok and trunk refused. A detector with a
--               hard-coded "main" fails this arm (coordinator ruling 2026-10-16)
--  13 NOPLAN    a seed but no plan binary   -> unknown(no-plan-binary)
--
-- Usage: tillandsias-plan script run scripts/lua/test-push-capability.lua

local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("push-capability", "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("push-capability", "git rev-parse --show-toplevel did not answer")
end
local LIB = ROOT .. "/images/default/lib-push-capability.sh"
local REL = "target/plan-scratch/push-capability-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
local ABS = ROOT .. "/" .. REL

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name .. (got and (" — " .. got) or "")) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

-- A stub git that answers only `ls-remote origin <pattern>` from $LSREMOTE
-- (a file of lines); $LSREMOTE_RC fails it. Anything else goes to real git.
local REALGIT = text.trim(proc.run({ argv = { "sh", "-c", "command -v git" }, timeout_ms = 10000 }).stdout or "")
fs.mkdir(REL .. "/bin")
fs.write(REL .. "/bin/git", "#!/bin/sh\n" ..
    "for a in \"$@\"; do [ \"$a\" = ls-remote ] && { [ -n \"${LSREMOTE_RC:-}\" ] && exit \"$LSREMOTE_RC\"; cat \"$LSREMOTE\" 2>/dev/null; exit 0; }; done\n" ..
    "exec " .. REALGIT .. " \"$@\"\n")
proc.run({ argv = { "chmod", "+x", ABS .. "/bin/git" }, timeout_ms = 10000 })

-- Drivers, sourced the way lib-common.sh sources the helper (the runner
-- refuses `bash -c` strings, so each is a file).
fs.write(REL .. "/drive-repo.sh", '. "$1"; tillandsias_push_capability "$2" octo/repo; rc=$?\n' ..
    'printf "%s\\nloud=%s rc=%s\\n%s\\n" "$TILLANDSIAS_PUSH_MACHINE" "$TILLANDSIAS_PUSH_LOUD" "$rc" "$TILLANDSIAS_PUSH_LINE"\n')
fs.write(REL .. "/drive-branch.sh", '. "$1"; tillandsias_push_branch "$2" "$3"\n' ..
    'printf "%s\\n%s\\n" "$TILLANDSIAS_PUSH_BRANCH_MACHINE" "$TILLANDSIAS_PUSH_BRANCH_LINE"\n')

local function repo_cap(refs, rc)
    local f = ABS .. "/refs-" .. tostring(math.random(100000, 999999))
    fs.write(REL .. "/" .. f:match("[^/]+$"), refs or "")
    local e = { PATH = ABS .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin"), LSREMOTE = f }
    if rc then e.LSREMOTE_RC = tostring(rc) end
    local r = proc.run({ argv = { "bash", ABS .. "/drive-repo.sh", LIB, ABS }, cwd = ROOT, timeout_ms = 30000, env = e })
    return text.trim(r.stdout or "")
end
local SHA = "0123456789abcdef0123456789abcdef01234567\t"
local function ref(s) return SHA .. "refs/tillandsias/upstream-auth/" .. s .. "\n" end

local o = repo_cap(ref("authorized/1700000000"))
arm("1 CAN-PUSH", o:find("^push_state=can%-push push_reason=%-\nloud=0 rc=0\npush: can push to octo/repo") ~= nil, o)
o = repo_cap(ref("denied/permission/1700000000"))
arm("2 READ-ONLY supported, loud, says read only and what still works",
    o:find("^push_state=read%-only push_reason=permission\nloud=1 rc=0") ~= nil
    and o:find("this token is read only for octo/repo", 1, true) ~= nil
    and o:find("local builds, local containers, locally served content", 1, true) ~= nil, o)
o = repo_cap(ref("denied/unauthenticated/1700000000"))
arm("3 REVOKED loud", o:find("^push_state=revoked push_reason=unauthenticated\nloud=1") ~= nil and o:find("REVOKED", 1, true) ~= nil, o)
o = repo_cap(ref("denied/sso/1700000000"))
arm("4 SSO loud", o:find("^push_state=sso%-required push_reason=sso\nloud=1") ~= nil, o)
o = repo_cap(ref("no-credential/1700000000"))
arm("5 NO-CRED loud", o:find("^push_state=no%-credential push_reason=%-\nloud=1") ~= nil, o)
o = repo_cap(ref("local-only/1700000000"))
arm("6 LOCAL not loud", o:find("^push_state=local%-only push_reason=%-\nloud=0") ~= nil, o)
o = repo_cap("")
arm("7 PENDING no verdict yet", o:find("^push_state=unknown push_reason=probe%-pending\nloud=0") ~= nil, o)
o = repo_cap("", 128)
arm("8 UNREACH the mirror does not answer", o:find("^push_state=unknown push_reason=mirror%-unreachable") ~= nil, o)
o = repo_cap(ref("denied/permission/1700000000") .. ref("authorized/1700009999"))
arm("9 NEWEST the larger epoch wins", o:find("^push_state=can%-push") ~= nil, o)

-- Branch level: real `discipline check-ref` over scratch seeds.
-- A checkout whose origin really carries the default branch AND the
-- integration branch `dev`, fetched, so the discipline's rule is backed by
-- reality and refuses (without it, check-ref only warns:
-- seed-ahead-of-reality).
local function g(dir, args)
    local argv = { "git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return proc.run({ argv = argv, timeout_ms = 30000 })
end
local function seed_repo(name, default_branch)
    local d = REL .. "/" .. name
    fs.mkdir(d)
    local abs = ABS .. "/" .. name
    g(abs, { "init", "-q", "-b", default_branch or "main", "." })
    g(abs, { "commit", "-q", "--allow-empty", "-m", "base" })
    if default_branch then
        fs.mkdir(REL .. "/" .. name .. "-origin")
        g(ABS .. "/" .. name .. "-origin", { "init", "-q", "--bare", "." })
        g(abs, { "remote", "add", "origin", ABS .. "/" .. name .. "-origin" })
        g(abs, { "branch", "dev" })
        g(abs, { "push", "-q", "origin", default_branch, "dev" })
        g(abs, { "fetch", "-q", "origin" })
    end
    if default_branch then
        fs.mkdir(d .. "/.tillandsias")
        fs.write(d .. "/.tillandsias/branch-discipline.yaml", table.concat({
            "version: 1", "level: 2", "enforcement:", "  default_branch: enforced", "  ref_grammar: warn",
            "default_branch: " .. default_branch, "integration:", "  linux: dev", "  forge: dev",
            "  windows: dev", "  macos: dev", 'work_ref: "work/[0-9]{3,4}-[a-z0-9]{4}"', "" }, "\n"))
    end
    return ABS .. "/" .. name
end
local function branch_cap(dir, branch, plan)
    local r = proc.run({ argv = { "bash", ABS .. "/drive-branch.sh", LIB, dir, branch }, cwd = ROOT, timeout_ms = 30000,
        env = { PATH = "/usr/bin:/bin", TILLANDSIAS_PLAN_BIN = plan or "" } })
    return text.trim(r.stdout or "")
end

o = branch_cap(seed_repo("free", nil), "main", PLAN)
arm("10 FREE no seed refuses nothing", o == "push_branch=free push_branch_reason=-", o)
local m = seed_repo("mainseed", "main")
o = branch_cap(m, "main", PLAN)
arm("11 REFUSED on the seed's protected branch: move away, with the seed's remedy",
    o:find("^push_branch=refused push_branch_reason=default%-branch%-protected") ~= nil
    and o:find("push: move away from main", 1, true) ~= nil and o:find("dev", 1, true) ~= nil, o)
local t = seed_repo("trunkseed", "trunk")
local o_main, o_trunk = branch_cap(t, "main", PLAN), branch_cap(t, "trunk", PLAN)
arm("12 FOLLOWS the seed's default branch changes, the detector follows (no hard-coded main)",
    o_main:find("^push_branch=ok ") ~= nil and o_trunk:find("^push_branch=refused ") ~= nil
    and o_trunk:find("move away from trunk", 1, true) ~= nil, o_main .. " || " .. o_trunk)
o = branch_cap(m, "main", nil)
arm("13 NOPLAN a seed but nothing to ask is unknown, never ok", o:find("^push_branch=unknown push_branch_reason=no%-plan%-binary") ~= nil, o)

proc.run({ argv = { "rm", "-rf", ABS }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:push-capability:" .. #failed .. "-failed", 1)
end
verdict.ok("push-capability", "13 arms")
