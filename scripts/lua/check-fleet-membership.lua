-- @env PATH HOME TILLANDSIAS_HOST_KIND TILLANDSIAS_PROJECT TILLANDSIAS_PROVIDER_LIMIT_STATE JOIN_FLEET_ROOT JOIN_FLEET_GIT_DIR JOIN_FLEET_PROBES
-- @trace order:1311-ajpm, order:1317-9ugn, order:1255-s4im, order:846-idhn, order:1957-msjs, order:2392-dn3f, spec:methodology-accountability
--
-- check-fleet-membership.lua — the NON-MUTATING verifier behind ./skills/join-the-fleet
-- (operator direction 2026-09-20). Ported from the .sh of the same name; every line and the
-- verdict are byte-identical.
--
-- It walks the fleet's joining requirements for the regime it detects and prints one line per step:
--   ok:join-the-fleet:<step>[:<detail>]      the requirement holds
--   skip:join-the-fleet:<step>:<reason>      not applicable in this regime, BY NAME
--   todo:join-the-fleet:<step>:<remedy>      what is LEFT, with the command that does it
--   note:join-the-fleet:<step>:<detail>      information the operator wants seen
-- and ONE verdict line last:
--   ok:join-the-fleet:<host>:<regime>:ran=<n> skipped=<m>            exit 0
--   todo:join-the-fleet:<host>:<regime>:todos=<k> ran=<n> skipped=<m> exit 1
--
-- THE CHECKER NEVER INSTALLS, CREATES, SEEDS OR STARTS ANYTHING. Every skip is named and the verdict
-- carries the counts: a green that does not say what it did not run is worthless.
--
-- REGIME (scripts/agent-identity.sh's precedence): forge when TILLANDSIAS_HOST_KIND=forge or the
-- .forge-startup-context.md marker exists; else by the shell's $OSTYPE: linux-immutable
-- (/run/ostree-booted or rpm-ostree), linux-mutable, macos, windows.
--
-- HERMETIC OVERRIDES, for fixtures only: JOIN_FLEET_ROOT (the checkout to inspect), JOIN_FLEET_GIT_DIR
-- (the git dir whose hooks/ are inspected), JOIN_FLEET_PROBES=0 (skip the probes that execute other
-- guards; counted as named skips, never as passes).
--
-- Usage: tillandsias-plan script run scripts/lua/check-fleet-membership.lua

-- ORDER 2246-fkea, inlined: a decider a fixture runs from a scratch copy has no lib/ beside it.
local SH
do
    local r = proc.run{ argv = { "git", "--exec-path" }, timeout_ms = 10000 }
    local ep = text.trim(r.stdout or "")
    if ep:find("^%a:/.*/libexec/git%-core$") then SH = (ep:gsub("/[^/]+/libexec/git%-core$", "/bin/bash.exe")) end
    SH = SH or "bash"
end
local function eget(k) local v = env.get(k); if v == nil or v == "" then return nil end; return v end

local ROOT_CWD -- set once ROOT resolves
-- A shell snippet, run in ROOT with the given positional args; its stdout and exit code.
local function sh(body, ...)
    local r = proc.run{ argv = { SH, "-s", "--", ... }, cwd = ROOT_CWD, stdin = body, timeout_ms = 600000 }
    return (r.stdout or ""):gsub("\r", ""), r.code
end
local function last_line(s)
    local l = ""
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do if line ~= "" then l = line end end
    return l
end

local root = eget("JOIN_FLEET_ROOT")
if not root then
    local r = proc.run{ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }
    root = text.trim(r.stdout or "")
    if r.code ~= 0 or root == "" then verdict.emit("refused:join-the-fleet:no-checkout:" .. (root or ""), 2) end
end
local probe = proc.run{ argv = { SH, "-s", "--", root }, timeout_ms = 30000, stdin = 'cd "$1" 2>/dev/null && pwd -W 2>/dev/null || { cd "$1" 2>/dev/null && pwd; }\n' }
local ROOT = text.trim((probe.stdout or ""):gsub("\r", ""))
if probe.code ~= 0 or ROOT == "" then verdict.emit("refused:join-the-fleet:no-checkout:" .. root, 2) end
ROOT_CWD = ROOT

local ran, skipped, todos = 0, 0, 0
local function ok(s) out.line("ok:join-the-fleet:" .. s); ran = ran + 1 end
local function skip(s) out.line("skip:join-the-fleet:" .. s); skipped = skipped + 1 end
local function todo(s) out.line("todo:join-the-fleet:" .. s); todos = todos + 1; ran = ran + 1 end
local function note(s) out.line("note:join-the-fleet:" .. s) end
local function git(...)
    local r = proc.run{ argv = { "git", "-C", ROOT, ... }, timeout_ms = 60000 }
    return text.trim((r.stdout or ""):gsub("\r", "")), r.code
end

-- ---- regime and identity ---------------------------------------------------
local REGIME = "unknown"
if eget("TILLANDSIAS_HOST_KIND") == "forge" or fs.exists(ROOT .. "/.forge-startup-context.md") then
    REGIME = "forge"
else
    local o = sh([==[
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    linux*|Linux*)
        if [ -e /run/ostree-booted ] || command -v rpm-ostree >/dev/null 2>&1; then echo linux-immutable; else echo linux-mutable; fi ;;
    darwin*|Darwin*) echo macos ;;
    msys*|cygwin*|MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo unknown ;;
esac
]==])
    REGIME = text.trim(o)
end
local HOST = text.trim((sh('bash "$1/scripts/agent-identity.sh" node-name 2>/dev/null || true\n', ROOT)))
if HOST == "" then HOST = text.trim((sh("hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown\n"))) end
local PROJECT = eget("TILLANDSIAS_PROJECT") or ROOT:match("([^/\\]+)[/\\]*$") or ROOT
local PROBES = eget("JOIN_FLEET_PROBES") or "1"

if REGIME == "forge" then note("session-name:" .. HOST .. "-" .. PROJECT .. "-forge")
elseif REGIME == "linux-immutable" then note("session-name:" .. HOST .. "-silverblue")
elseif REGIME == "linux-mutable" then
    note("session-name:" .. HOST .. "-" .. text.trim((sh('(. /etc/os-release 2>/dev/null; echo "${ID:-linux}")\n'))))
elseif REGIME == "macos" then note("session-name:" .. HOST .. "-macos")
elseif REGIME == "windows" then note("session-name:" .. HOST .. "-windows")
else note("session-name:" .. HOST .. "-unknown") end

-- ---- 1. platform branch, or a work ref ------------------------------------
local want = ({ ["linux-immutable"] = "linux-next", ["linux-mutable"] = "linux-next", macos = "osx-next", windows = "windows-next" })[REGIME] or ""
local branch, brc = git("symbolic-ref", "--short", "HEAD")
if brc ~= 0 or branch == "" then branch = "detached" end
if branch:sub(1, 5) == "work/" then
    -- ORDER 1317-9ugn: a work ref is where a host WORKS; a correct place to be, never a todo.
    note("branch:" .. branch)
    ok("branch:work-ref:" .. branch)
elseif want == "" then
    if branch == "linux-next" or branch == "osx-next" or branch == "windows-next" then ok("branch:" .. branch)
    else todo("branch:seeded-off-a-platform-branch:" .. branch .. ":git checkout <linux-next|osx-next|windows-next>") end
elseif branch == want then
    ok("branch:" .. branch)
else
    todo("branch:" .. branch .. ":git checkout " .. want)
end

-- ---- 2. hooks ----------------------------------------------------------------
-- ORDER 1255-s4im: inspect the hook git will RUN. With core.hooksPath set git ignores .git/hooks,
-- so `--git-path hooks` resolves it exactly as install-hooks.sh does. JOIN_FLEET_GIT_DIR stays the
-- seam for a git dir that is not a checkout.
local hooks_dir
local gd = eget("JOIN_FLEET_GIT_DIR")
if gd then
    hooks_dir = gd .. "/hooks"
else
    local hp, hrc = git("rev-parse", "--path-format=absolute", "--git-path", "hooks")
    if hrc ~= 0 or hp == "" then
        local g = git("rev-parse", "--git-dir")
        hp = (g ~= "" and g or ".git") .. "/hooks"
    end
    hooks_dir = hp
end
local hv = text.trim((sh('[ -f "$1/pre-push" ] && grep -o -m1 -E "tillandsias-pre-push-v[0-9]+" "$1/pre-push" 2>/dev/null || true\n', hooks_dir)))
if hv ~= "" then ok("hooks:" .. hv) else todo("hooks:scripts/install-hooks.sh") end

-- ---- 2b. rerere (1317-9ugn: a work ref merges trunk more than once) ---------
if git("config", "--get", "rerere.enabled") == "true" then ok("rerere") else todo("rerere:git config rerere.enabled true") end

-- ---- 3. builder toolbox (Linux bare metal only) ----------------------------
if REGIME:sub(1, 6) == "linux-" then
    local t = text.trim((sh([==[
if command -v toolbox >/dev/null 2>&1; then
    case "$(toolbox list --containers 2>/dev/null || true)" in *tillandsias-builder*) echo have ;; *) echo missing ;; esac
else echo none; fi
]==])))
    if t == "have" then ok("toolbox:tillandsias-builder")
    elseif t == "missing" then todo("toolbox:scripts/with-tillandsias-builder.sh true")
    else todo("toolbox:no-toolbox-command:install toolbox (methodology toolbox_first_scripts)") end
else
    skip("toolbox:" .. REGIME)
end

-- ---- 4. plan binary resolves ------------------------------------------------
local PB = ""
if fs.exists(ROOT .. "/scripts/plan-binary-probe.sh") then
    PB = text.trim((sh('cd "$1" || exit 0\n. scripts/plan-binary-probe.sh\np="$(resolve_plan_binary 2>/dev/null || true)"\n[ -n "$p" ] && [ -x "$p" ] && printf "%s" "$p"\n', ROOT)))
end
if PB ~= "" then ok("plan-binary:" .. PB) else todo("plan-binary:scripts/cycle-preflight.sh") end

-- A guard run from ROOT through the shell: its whole output and exit code.
local function guard(cmd) return sh('cd "$1" || exit 90\n' .. cmd .. ' 2>&1\n', ROOT) end

-- ---- 5. plan binary current (the 1287-h6qn content-hash lane) --------------
if PROBES ~= "1" then skip("plan-binary-current:probes-disabled")
elseif PB == "" then skip("plan-binary-current:no-binary")
elseif fs.exists(ROOT .. "/scripts/check-plan-binary-current.sh") then
    local o, rc = guard('bash scripts/check-plan-binary-current.sh')
    if rc == 0 then ok("plan-binary-current") else todo("plan-binary-current:" .. last_line(o)) end
else skip("plan-binary-current:no-checker") end

-- ---- 6. credential channel (982-sguu: blocked = stop and report) -----------
if PROBES ~= "1" then skip("credential-channel:probes-disabled")
elseif fs.exists(ROOT .. "/scripts/check-credential-channel.sh") then
    local o, rc = guard('bash scripts/check-credential-channel.sh')
    local v
    for line in (o .. "\n"):gmatch("([^\n]*)\n") do
        if not v and (line:find("^ok:") or line:find("^blocked:") or line:find("^skip:")) then v = line end
    end
    v = v or last_line(o)
    if rc == 0 then ok("credential-channel:" .. v) else todo("credential-channel:" .. v .. ":stop-and-report") end
else skip("credential-channel:no-guard") end

-- ---- 7. daily maintenance (bare metal; forges exempt by the gate itself) ---
if fs.exists(ROOT .. "/scripts/check-daily-maintenance.sh") then
    local last = last_line((guard('bash scripts/check-daily-maintenance.sh check')))
    if last == "skip:forge-exempt" then skip("daily-maintenance:forge-exempt")
    elseif last:sub(1, 3) == "ok:" then ok("daily-maintenance:" .. last)
    else todo("daily-maintenance:" .. last .. ":run the Start Of Day gate (skills/meta-orchestration)") end
else skip("daily-maintenance:no-gate") end

-- ---- 8. experts (ask, don't read: the MCP experts must answer) -------------
if PROBES ~= "1" then skip("experts:probes-disabled")
elseif fs.exists(ROOT .. "/scripts/check-mcp-expert-health.sh") then
    local o, rc = guard('bash scripts/check-mcp-expert-health.sh')
    if rc == 0 then ok("experts:" .. last_line(o)) else todo("experts:" .. last_line(o) .. ":scripts/dev-host-experts.sh") end
else skip("experts:no-probe") end

-- ---- 9. substrate (bare-metal Linux: ./skills/initialize-bare-metal-host) --
if REGIME:sub(1, 6) == "linux-" then
    if PROBES ~= "1" then skip("substrate:probes-disabled")
    elseif PB ~= "" and fs.exists(ROOT .. "/scripts/lua/check-bare-metal-host-initialized.lua") then
        -- 2170-ji2b: the checker is Lua on the one runner (PB, section 4).
        local o, rc = sh('cd "$1" || exit 90\n"$2" script run "$1/scripts/lua/check-bare-metal-host-initialized.lua" 2>&1\n', ROOT, PB)
        local last = last_line(o)
        if last:sub(1, 5) == "skip:" then skip("substrate:" .. last)
        elseif rc == 0 then ok("substrate:" .. last) else todo("substrate:" .. last) end
    else skip("substrate:1312-i6da-not-landed") end
elseif REGIME == "forge" then skip("substrate:forge-has-no-podman")
else skip("substrate:" .. REGIME .. ":the-tray-provisions") end

-- ---- 10. capability row (846-idhn: a first-ever host row enters the base) --
local caprow = false
if fs.exists(ROOT .. "/plan/index.yaml") then
    local _, rc = sh('grep -q -E -e "host_id:[[:space:]]*${2}([[:space:]]|$)" "$1/plan/index.yaml" 2>/dev/null\n', ROOT, HOST)
    caprow = rc == 0
end
if caprow then ok("capability-row:" .. HOST)
elseif REGIME == "forge" then skip("capability-row:forge-rows-belong-to-the-host")
else todo("capability-row:846-idhn:add a capabilities row for host_id " .. HOST .. " to plan/index.yaml (never as a fragment)") end

-- ---- 11. provider-limit relay (1957-msjs): a deferred push is retried by the slot --
local state = eget("TILLANDSIAS_PROVIDER_LIMIT_STATE") or ((eget("HOME") or "/tmp") .. "/.local/state/tillandsias")
local _, drc = sh('[ -s "$1" ]\n', state .. "/provider-limit-deferred")
if drc == 0 then
    todo("provider-limit-deferred:1957-msjs:a provider usage limit has not reached trunk yet; run scripts/provider-limit-relay.sh retry")
end

-- ---- verdict ----------------------------------------------------------------
if todos == 0 then verdict.emit("ok:join-the-fleet:" .. HOST .. ":" .. REGIME .. ":ran=" .. ran .. " skipped=" .. skipped, 0) end
verdict.emit("todo:join-the-fleet:" .. HOST .. ":" .. REGIME .. ":todos=" .. todos .. " ran=" .. ran .. " skipped=" .. skipped, 1)
