-- @trace order:1124-7f3u, order:889-twhe, order:531-*, order:1926-pmau, order:2217-ab8h, order:2400-prg4
-- @env PATH HOME
--
-- test-pre-push-plan-lane-fails-closed-without-binary.lua — pin that the pre-push
-- plan-only lane REFUSES a fragment-bearing push when no runnable tillandsias-plan
-- resolves, instead of passing it with a "checks skipped" note. Ported from
-- test-pre-push-plan-lane-fails-closed-without-binary.sh (2400-prg4); same arms, in its order.
--
-- The lane's fail-closed test (889-twhe) is satisfied by yq ALONE, which is right for
-- per-blob validation and wrong for the FOLD (`check --strict-fragments`, the
-- status-loss guard): no YAML parser computes either. A host with yq and no plan binary
-- reached those checks and skipped them beside a green push (2026-09-12: yoga's honest
-- reopen of 1115-yvrq reached trunk carrying a shape build.sh --check refuses).
--
--   arm0  PREMISE: no plan binary resolves under the scrubbed env (asked, not assumed)
--   arm1  fragment-bearing push, no binary: REFUSED (full gate required), names the
--         missing instrument, and no "checks skipped" note
--   arm2  NEGATIVE CONTROL: with a current, runnable binary the fast lane still accepts
--         (named-skipped when this checkout's binary is absent or stale, 2217-ab8h)
--   arm3  an issues-only push with no binary is still accepted (the refusal is scoped)
--
-- yq is a STUB on purpose (the hook's two calls only): the arm tests what happens AFTER
-- the yq tier passes. The scratch repo pins core.hooksPath (a global one would replace
-- it). TILLANDSIAS_SURFACE_ROOT is dropped (1926-pmau), and TILLANDSIAS_PLAN_BIN and
-- CARGO_TARGET_DIR are dropped from the no-binary pushes: they are probe routes. The hook
-- never re-enters build.sh (it only names it in refusals), so gate_inherit is n/a.
--
-- GRAMMAR ok:pre-push-plan-lane-fails-closed-without-binary:<n> arms
--       | violation:pre-push-plan-lane-fails-closed-without-binary:<n>-failed
--       | refused:pre-push-plan-lane-fails-closed-without-binary:<reason>

local fixture = require "common.fixture"
local T = fixture.new("pre-push-plan-lane-fails-closed-without-binary")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local GUARD_REL = "scripts/hooks/pre-push-local-gate.sh"
if not fs.exists(GUARD_REL) then T:refuse("guard-missing", GUARD_REL) end
local W = T:scratch()
local WC, BARE = W.abs .. "/wc", W.abs .. "/bare.git"
local WCR = W.rel .. "/wc"
local GITUNSET = { "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_PREFIX",
    "TILLANDSIAS_SURFACE_ROOT" }
local GITENV = { GIT_TERMINAL_PROMPT = "0" }

local function G(...)
    local argv = { "git", "-C", WC, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", ... }
    argv.env, argv.env_unset, argv.timeout_ms = GITENV, GITUNSET, 60000
    local r = T:run(argv)
    if r.code ~= 0 then T:refuse("setup-failed", "git " .. table.concat({ ... }, " ") .. ": " .. tostring(r.stderr or r.why)) end
    return text.trim(r.stdout or "")
end

T:must{ "git", "init", "-q", "--bare", BARE, env_unset = GITUNSET }
T:must{ "git", "init", "-q", "-b", "linux-next", WC, env_unset = GITUNSET }
G("remote", "add", "origin", BARE)
G("config", "core.hooksPath", ".git/hooks")
for _, d in ipairs{ "scripts/hooks", "scripts/lua", "plan/issues", "plan/index.d" } do fs.mkdir(WCR .. "/" .. d) end
T:must{ "cp", ROOT .. "/" .. GUARD_REL, WC .. "/" .. GUARD_REL }
-- check-issue-citation-convention.sh is needed by arm 3: without it an issues-only push
-- is refused for a DIFFERENT missing validator.
for _, f in ipairs{ "plan-binary-probe.sh", "gate-stamp.sh", "common.sh", "check-issue-citation-convention.sh" } do
    if fs.exists("scripts/" .. f) then T:must{ "cp", ROOT .. "/scripts/" .. f, WC .. "/scripts/" .. f } end
end
if fs.exists("scripts/lua/check-fragment-status-loss.lua") then
    T:must{ "cp", ROOT .. "/scripts/lua/check-fragment-status-loss.lua", WC .. "/scripts/lua/" }
end
T:must{ "chmod", "+x", WC .. "/" .. GUARD_REL }
fs.write(WCR .. "/plan/index.yaml", "packets: []\n")
-- The Lua status-loss guard's command-policy audit lands in .cache/ (gitignored for real).
fs.write(WCR .. "/.gitignore", ".cache/\n")
fs.write(WCR .. "/plan/issues/existing.md", "base\n")
G("add", "-A"); G("commit", "-q", "-m", "base")
G("push", "-q", "-u", "origin", "linux-next")

-- A PATH with no tillandsias-plan on it, and a yq stub: yq PRESENT, plan binary ABSENT.
local EB = W.abs .. "/emptybin"
fs.mkdir(W.rel .. "/emptybin")
for _, t in ipairs{ "git", "bash", "sh", "env", "grep", "sed", "awk", "cat", "mktemp", "rm", "cp", "mkdir", "printf", "head",
        "tail", "tr", "sort", "comm", "wc", "dirname", "basename", "cut", "find", "xargs", "chmod", "date" } do
    local p = fixture.which(t)
    if p then T:run{ "ln", "-sf", p, EB .. "/" .. t } end
end
fs.write(W.rel .. "/emptybin/yq", table.concat({
    "#!/usr/bin/env bash",
    "# Minimal stand-in for the two calls scripts/hooks/pre-push-local-gate.sh makes.",
    'expr="" ; file=""',
    "while [ $# -gt 0 ]; do",
    '    case "$1" in',
    "        eval) shift ;;",
    "        -*) shift ;;",
    '        *) if [ -z "$expr" ]; then expr="$1"; else file="$1"; fi; shift ;;',
    "    esac",
    "done",
    '[ -r "$file" ] || exit 1',
    'case "$expr" in',
    "    type)",
    "        if grep -qE '^[[:space:]]*[A-Za-z0-9_.-]+:' \"$file\"; then echo '!!map'; else echo '!!seq'; fi",
    "        ;;",
    "    *) : ;;",
    "esac",
    "exit 0", "" }, "\n"))
T:must{ "chmod", "+x", EB .. "/yq" }
local NOPLAN_ENV = { PATH = EB, GIT_TERMINAL_PROMPT = "0" }
local NOPLAN_UNSET = { "TILLANDSIAS_PLAN_BIN", "CARGO_TARGET_DIR" }
for _, k in ipairs(GITUNSET) do NOPLAN_UNSET[#NOPLAN_UNSET + 1] = k end

local function refline()
    return "refs/heads/linux-next " .. G("rev-parse", "HEAD") .. " refs/heads/linux-next " .. G("rev-parse", "origin/linux-next") .. "\n"
end
local function push(env, unset)
    local r = T:run{ SH, GUARD_REL, "origin", BARE, cwd = WC, stdin = refline(), env = env, env_unset = unset, timeout_ms = 300000 }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end

-- ARM 0: ask the probe, under exactly arm 1's environment.
fs.write(W.rel .. "/probe.sh", ". scripts/plan-binary-probe.sh; resolve_plan_binary 2>/dev/null\n")
local pr = T:run{ SH, W.abs .. "/probe.sh", cwd = WC, env = NOPLAN_ENV, env_unset = NOPLAN_UNSET }
local says = text.trim(pr.stdout or "")
if says ~= "" then
    T:arm("arm0 PREMISE: no plan binary resolves under the scrubbed environment", false,
        "'" .. says .. "' still resolves; neutralise that route (a candidate in scripts/plan-binary-probe.sh) and re-run")
    T:finish()
end
T:arm("arm0 the premise holds — no plan binary resolves under the scrubbed environment", true, "")

-- ARM 1
fs.write(WCR .. "/plan/index.d/20260912t000000z-arm1.yaml", "packets: []\n")
G("add", "-A"); G("commit", "-q", "-m", "arm1: a fragment-only push")
local rc, o = push(NOPLAN_ENV, NOPLAN_UNSET)
T:arm("arm1 a fragment-bearing push with no runnable plan binary is REFUSED (full gate required)",
    rc ~= 0 and text.contains(o, "full gate required"), "rc=" .. tostring(rc) .. ": " .. o:sub(1, 400))
local lo = o:lower()
T:arm("arm1 the refusal names the missing INSTRUMENT, not a defect in the ledger",
    lo:find("cannot run", 1, true) or lo:find("cannot fold", 1, true) or lo:find("no runnable tillandsias-plan", 1, true)
        or text.contains(o, "does NOT run here"), o:sub(1, 400))
T:arm("arm1 no 'checks skipped' note (a skip here is a refusal, 1124-7f3u)", not lo:find("checks skipped", 1, true), o:sub(1, 400))

-- ARM 2: the checkout's own binary, absolute, and only if current for this checkout.
local bin = fixture.plan_binary()
if bin ~= "" and not fixture.is_abs(bin) then bin = ROOT .. "/" .. bin:gsub("^%./", "") end
local current = false
if bin ~= "" then
    local vs = T:run{ bin, "validator-surface-hash", "--check", cwd = ROOT }
    current = text.contains((vs.stdout or "") .. (vs.stderr or ""), "ok:validator-surface:")
        and T:run{ bin, "capabilities", cwd = ROOT }.code == 0
end
if current then
    local env2 = { TILLANDSIAS_PLAN_BIN = bin, GIT_TERMINAL_PROMPT = "0" }
    local rc2, o2 = push(env2, GITUNSET)
    T:arm("arm2 (negative control): with a runnable binary the fast lane still accepts the same push",
        rc2 == 0 and text.contains(o2, "plan-only lane"), "rc=" .. tostring(rc2) .. ": " .. o2:sub(1, 400))
else
    out.line("skip:arm2:" .. (bin == "" and "no-runnable-plan-binary" or "plan-binary-not-current-for-this-checkout"))
end

-- ARM 3
G("rm", "-q", "--cached", "plan/index.d/20260912t000000z-arm1.yaml")
T:must{ "rm", "-f", WC .. "/plan/index.d/20260912t000000z-arm1.yaml" }
fs.write(WCR .. "/plan/issues/arm3-note.md", "a capture\n")
G("add", "-A"); G("commit", "-q", "-m", "arm3: an issues-only push")
local rc3, o3 = push(NOPLAN_ENV, NOPLAN_UNSET)
T:arm("arm3 an issues-only push is still accepted with no plan binary (refusal stays scoped)", rc3 == 0,
    "rc=" .. tostring(rc3) .. ": " .. o3:sub(1, 400))

T:finish()
