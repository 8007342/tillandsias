-- @trace order:1443-sb9b, spec:branch-discipline, order:2340-psb5
-- @env PATH HOME
--
-- test-pre-push-main-branch-affordance.lua — the main-branch pre-push affordance
-- (scripts/lua/pre-push-main-branch-affordance.lua behind the stub
-- scripts/hooks/pre-push-main-branch-affordance.sh), order 1443-sb9b.
-- Ported from test-pre-push-main-branch-affordance.sh (2340-psb5); same five arms.
--
--   1 a feed targeting refs/heads/main prints blocked:main-branch-affordance (rc 1) and a
--     remedy naming the seed's integration branch for the platform (forge -> linux-next)
--     with source=seed
--   2 the stub is <= 15 lines, runs `"$PLAN" lua` on the .lua, and with
--     TILLANDSIAS_PLAN_BIN at a non-runnable file prints
--     blocked:main-branch-affordance:no-plan-binary (rc 1)
--   3 NEGATIVE CONTROL: a feed naming only refs/heads/linux-next, or no feed, prints
--     ok:main-branch-affordance (rc 0)
--   4 FLOOR: from a project with no seed, main is ok (level 0 refuses nothing)
--   5 FAIL-CLOSED: a runnable binary whose `discipline` answers junk prints
--     blocked:main-branch-affordance:discipline-unanswered (rc 1)
--
-- GRAMMAR ok:main-branch-affordance:5 arms | violation:main-branch-affordance:<n>-failed
--         | refused:main-branch-affordance:no-plan-binary

local fixture = require "common.fixture"
local T = fixture.new("main-branch-affordance")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local HOOK_REL = "scripts/hooks/pre-push-main-branch-affordance.sh"
local HOOK = ROOT .. "/" .. HOOK_REL
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary", "build one: cargo build --release -p tillandsias-plan") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local W = T:scratch()

-- The hook, fed on stdin; stdout and stderr captured apart, never piped into a verdict.
local function hook(dir, feed, extra)
    local e = { TILLANDSIAS_PLAN_BIN = PLAN }
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = proc.run{ argv = { SH, HOOK }, cwd = dir, stdin = feed ~= "" and (feed .. "\n") or "\n", env = e,
        env_unset = { "TILLANDSIAS_HOST_KIND" }, timeout_ms = 60000 }
    return r.code, r.stdout or "", r.stderr or ""
end
local function first(s) return (s:match("^[^\n]*") or "") end
local function why(rc, out, err) return "rc=" .. tostring(rc) .. " out=[" .. out .. "] err=[" .. err:sub(1, 300) .. "]" end

-- 1 — main is refused, and the remedy comes from the seed.
local rc, out, err = hook(ROOT, "refs/heads/x 1111 refs/heads/main 2222", { TILLANDSIAS_HOST_KIND = "forge" })
T:arm("1 main blocked; the remedy names the seed's forge branch (linux-next) with source=seed",
    rc == 1 and first(out) == "blocked:main-branch-affordance"
        and text.contains(err, "work on 'linux-next', the forge integration branch in the seed")
        and text.contains(err, "source=seed level=2 enforcement=enforced"), why(rc, out, err))

-- 2 — the stub is small, runs the Lua, and fails closed without a binary.
-- NON-RUNNABLE ON EVERY FILESYSTEM (1556-b2tq): an empty file is mode 777 over 9p and
-- bash runs it as an empty script that exits 0; a shebang naming an interpreter that
-- does not exist fails to execute whatever the mode.
local stub = fs.read(HOOK_REL)
local _, lines = stub:gsub("\n", "")
fs.write(W.rel .. "/not-runnable", "#!/nonexistent/tillandsias-not-an-interpreter\n")
rc, out, err = hook(ROOT, "refs/heads/x 1 refs/heads/linux-next 2", { TILLANDSIAS_PLAN_BIN = W.abs .. "/not-runnable" })
T:arm("2 the stub is <= 15 lines, runs the .lua, and fails closed (no-plan-binary, rc 1)",
    lines <= 15 and text.contains(stub, '"$PLAN" lua "$ROOT/scripts/lua/pre-push-main-branch-affordance.lua"')
        and rc == 1 and first(out) == "blocked:main-branch-affordance:no-plan-binary",
    "lines=" .. lines .. " " .. why(rc, out, err))

-- 3 — NEGATIVE CONTROL: nothing targeting the protected branch passes.
local rc_a, out_a = hook(ROOT, "refs/heads/linux-next 1 refs/heads/linux-next 2")
local rc_b, out_b = hook(ROOT, "")
T:arm("3 CONTROL linux-next and an empty feed are ok:main-branch-affordance, rc 0",
    rc_a == 0 and text.trim(out_a) == "ok:main-branch-affordance" and rc_b == 0 and text.trim(out_b) == "ok:main-branch-affordance",
    "linux-next rc=" .. tostring(rc_a) .. " [" .. out_a .. "] | empty rc=" .. tostring(rc_b) .. " [" .. out_b .. "]")

-- 4 — FLOOR: a project with no seed pushes main freely. A scratch repo of its own.
fs.mkdir(W.rel .. "/bare")
T:must{ "git", "-C", W.abs .. "/bare", "-c", "init.defaultBranch=main", "init", "-q" }
rc, out, err = hook(W.abs .. "/bare", "refs/heads/main 1 refs/heads/main 2")
T:arm("4 FLOOR no seed (level 0): main is ok", rc == 0 and text.trim(out) == "ok:main-branch-affordance", why(rc, out, err))

-- 5 — FAIL-CLOSED: a runnable binary that cannot answer the discipline question.
fs.write(W.rel .. "/junk-plan", '#!/usr/bin/env bash\ncase "${1:-}" in discipline) echo "usage: nothing here"; exit 2 ;; esac\n'
    .. 'exec "' .. PLAN .. '" "$@"\n')
T:must{ "chmod", "+x", W.abs .. "/junk-plan" }
rc, out, err = hook(ROOT, "refs/heads/x 1 refs/heads/linux-next 2", { TILLANDSIAS_PLAN_BIN = W.abs .. "/junk-plan" })
T:arm("5 FAIL-CLOSED an unanswerable discipline question is blocked:...:discipline-unanswered, rc 1",
    rc == 1 and first(out) == "blocked:main-branch-affordance:discipline-unanswered", why(rc, out, err))

T:finish()
