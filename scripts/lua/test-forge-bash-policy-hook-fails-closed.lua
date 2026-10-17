-- @trace order:1750-a4re, order:1443-we89, spec:command-policies
-- @env PATH TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-forge-bash-policy-hook-fails-closed.lua — the forge's Claude Bash hook
-- (images/default/bash-policy-hook) refuses when it cannot decide, and the host
-- bridge (scripts/hooks/claude-pretooluse-command-policy.sh) does not.
--
-- THE DEFECT (1750-a4re, v56.10.16.1 macOS smoke). config-overlay/claude/
-- settings.json named the bare `tillandsias-plan policy classify-bash --hook`.
-- No forge image shipped tillandsias-plan, so outside a Tillandsias checkout
-- the hook exited 127, which Claude Code treats as a non-blocking error: every
-- rule, 1724's `pkill -f` refusal included, was silently off.
--
--   1 SHIPPED   the command settings.json names is an absolute path that the
--               forge Containerfile installs from an executable in the image
--               context, and the Containerfile installs policy-bin/ where the
--               hook looks for the decider
--   2 ABSENT    in an image-shaped HOME with no decider, `pkill -f vite` is
--               refused: exit 2, refused:bash-policy:decider-absent, why, remedy
--   3 DECIDES   with a real tillandsias-plan, `pkill -f vite` is refused by the
--               policy itself and `ls -la` is allowed, silently
--   4 FAILED    a decider that runs but exits 2 without a verdict is refused as
--               decider-failed, not allowed
--   5 PRE-FIX   the settings.json command at PRE_REV, run as Claude Code runs
--               it in that same HOME, exits 127: the fail-open (red today)
--   6 SPLIT     on the same missing binary the host bridge ALLOWS with its
--               note (1443-we89: a developer machine may lack it) while the
--               forge hook refuses; the hook never sources the host bridge
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-bash-policy-hook-fails-closed.lua

local PRE_REV = "9f00cdb08"
local HOOK = "images/default/bash-policy-hook"
local SETTINGS = "images/default/config-overlay/claude/settings.json"
local CONTAINERFILE = "images/default/Containerfile"
local BRIDGE = "scripts/hooks/claude-pretooluse-command-policy.sh"

local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("forge-bash-policy-hook", "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("forge-bash-policy-hook", "git rev-parse --show-toplevel did not answer")
end
if not fs.exists(HOOK) then
    verdict.emit("violation:forge-bash-policy-hook:no-hook", 1, HOOK .. " does not exist (1750-a4re)")
end

local REL = "target/plan-scratch/forge-bash-policy-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
fs.mkdir(REL .. "/home/.claude")
local HOME = W .. "/home"

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local function hook_json(cmd)
    return '{"tool_name":"Bash","tool_input":{"command":"' .. cmd .. '"},"cwd":"' .. HOME .. '"}'
end
-- run(argv, stdin, extra_env) -> code, stdout, stderr
local function run(argv, stdin, extra)
    local e = { PATH = "/usr/bin:/bin", HOME = HOME, TMPDIR = W, TILLANDSIAS_HOST_KIND = "forge",
        TILLANDSIAS_POLICY_AUDIT_LOG = W .. "/audit.jsonl",
        -- the runner passes its declared @env through; none may name a binary here
        TILLANDSIAS_PLAN_BIN = "", TILLANDSIAS_SCRIPT_RUNNER_BIN = "",
        -- nor the base env's CARGO_TARGET_DIR (1593-1ny6): under
        -- with-wsl2-builder.sh it is absolute and holds a real plan binary,
        -- which the probe tries first, so arm 6's bridge found one (667-kfyn)
        CARGO_TARGET_DIR = "" }
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = proc.run({ argv = argv, stdin = stdin, env = e, cwd = HOME, timeout_ms = 60000 })
    return r.code or -1, r.stdout or "", r.stderr or ""
end
local PKILL = hook_json("pkill -f vite")

-- ── 1 SHIPPED ──────────────────────────────────────────────────────────────
local settings = fs.read(SETTINGS)
local cmd = settings:match('"command"%s*:%s*"([^"]+)"')
local cf = fs.read(CONTAINERFILE)
local hook_src = fs.read(HOOK)
local hook_mode = text.trim(proc.run({ argv = { "stat", "-c", "%a", ROOT .. "/" .. HOOK }, timeout_ms = 10000 }).stdout or "")
arm("1 SHIPPED settings.json names an absolute path the Containerfile installs from an executable image file, and policy-bin/ lands where the hook looks",
    cmd ~= nil and cmd:sub(1, 1) == "/"
    and cf:find("COPY bash-policy-hook " .. cmd, 1, true) ~= nil
    and hook_mode:match("[157]$") ~= nil
    and cf:find("COPY policy-bin/ /usr/local/lib/tillandsias/policy-bin/", 1, true) ~= nil
    and hook_src:find("/usr/local/lib/tillandsias/policy-bin/tillandsias-plan", 1, true) ~= nil,
    "cmd=" .. tostring(cmd) .. " mode=" .. hook_mode)

-- ── 2 ABSENT ───────────────────────────────────────────────────────────────
local rc, o, e = run({ "bash", ROOT .. "/" .. HOOK }, PKILL, { TILLANDSIAS_FORGE_POLICY_BIN = W .. "/no-such-plan" })
arm("2 ABSENT with no decider, pkill -f is refused (exit 2, decider-absent, why, remedy)",
    rc == 2 and e:find("refused:bash-policy:decider-absent", 1, true) ~= nil
    and e:find("why: ", 1, true) ~= nil and e:find("remedy: ", 1, true) ~= nil, rc .. " " .. e)
local forge_rc = rc

-- ── 3 DECIDES ──────────────────────────────────────────────────────────────
rc, o, e = run({ "bash", ROOT .. "/" .. HOOK }, PKILL, { TILLANDSIAS_FORGE_POLICY_BIN = PLAN })
local rc_ls, o_ls, e_ls = run({ "bash", ROOT .. "/" .. HOOK }, hook_json("ls -la"), { TILLANDSIAS_FORGE_POLICY_BIN = PLAN })
arm("3 DECIDES with the decider, pkill -f is refused by the policy and ls -la is allowed, silently",
    rc == 2 and e:find("refused:bash-policy:", 1, true) ~= nil and e:find("decider-", 1, true) == nil
    and rc_ls == 0 and o_ls == "", rc .. " " .. e .. " / " .. rc_ls .. " [" .. o_ls .. "] " .. e_ls)

-- ── 4 FAILED ───────────────────────────────────────────────────────────────
fs.write(REL .. "/stale-plan", '#!/usr/bin/env bash\n[ "${1:-}" = capabilities ] && { echo policy; exit 0; }\necho "usage: tillandsias-plan policy eval" >&2\nexit 2\n')
proc.run({ argv = { "chmod", "+x", W .. "/stale-plan" }, timeout_ms = 10000 })
rc, o, e = run({ "bash", ROOT .. "/" .. HOOK }, hook_json("git status"), { TILLANDSIAS_FORGE_POLICY_BIN = W .. "/stale-plan" })
arm("4 FAILED a decider that exits 2 without a verdict is refused as decider-failed",
    rc == 2 and e:find("refused:bash-policy:decider-failed", 1, true) ~= nil, rc .. " " .. e)

-- ── 5 PRE-FIX ──────────────────────────────────────────────────────────────
local pre = proc.run({ argv = { "git", "show", PRE_REV .. ":" .. SETTINGS }, cwd = ROOT, timeout_ms = 30000 })
local pre_cmd = (pre.stdout or ""):match('"command"%s*:%s*"([^"]+)"')
if pre.code ~= 0 or pre_cmd ~= "tillandsias-plan policy classify-bash --hook" then
    arm("5 premise: settings.json at " .. PRE_REV .. " names the bare classify-bash command", false, tostring(pre_cmd))
else
    fs.write(REL .. "/pre-hook.sh", pre_cmd .. "\n")
    rc, o, e = run({ "bash", W .. "/pre-hook.sh" }, PKILL)
    arm("5 PRE-FIX the pre-1750 command exits 127 in a HOME with no decider: Claude Code's non-blocking error, so pkill -f ran unchecked",
        rc == 127, rc .. " " .. e)
end

-- ── 6 SPLIT ────────────────────────────────────────────────────────────────
fs.mkdir(REL .. "/host/scripts/hooks")
fs.write(REL .. "/host/" .. BRIDGE, fs.read(BRIDGE))
fs.write(REL .. "/host/scripts/plan-binary-probe.sh", fs.read("scripts/plan-binary-probe.sh"))
-- Its own repository, so the probe cannot climb to this checkout's target/.
proc.run({ argv = { "git", "init", "-q", W .. "/host" }, timeout_ms = 30000 })
rc, o, e = run({ "bash", W .. "/host/" .. BRIDGE }, PKILL, { TILLANDSIAS_HOST_KIND = "bare-metal" })
-- A code line (not a comment) that sources or execs the bridge.
local sources_bridge = false
for _, l in ipairs(text.lines(hook_src)) do
    if not l:match("^%s*#") and l:find("claude-pretooluse-command-policy", 1, true) then sources_bridge = true end
end
arm("6 SPLIT on the same missing binary the host bridge allows with its note (1443-we89) and the forge hook refuses; the hook never sources the bridge",
    rc == 0 and e:find("note:pretooluse:no-plan-binary", 1, true) ~= nil and forge_rc == 2
    and not sources_bridge and hook_src:find("allowed unchecked", 1, true) == nil,
    rc .. " " .. e .. " forge_rc=" .. forge_rc .. " sources_bridge=" .. tostring(sources_bridge))

proc.run({ argv = { "rm", "-rf", W }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("refused:forge-bash-policy-hook:" .. #failed .. "-of-6", 1)
end
verdict.emit("ok:forge-bash-policy-hook:6", 0)
