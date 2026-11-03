-- @env PATH, TILLANDSIAS_GIT_IMAGE
-- @trace order:1978-n8c6, spec:git-mirror-service
--
-- test-git-mirror-vault-sink-wait-is-an-event.lua — the git mirror's Vault
-- Agent wait returns when the token sink is written, not on the next
-- one-second tick, and still fails loudly on a dead or silent agent (1978-n8c6).
--
-- MEASURED on yoga 2026-11-03: "agent.sink.file: token written" at
-- 15:11:54.391 and "[git-service] Vault Agent auto-auth ready" at 15:11:55.273.
-- The ~0.9 s between them was `sleep 1` in start_vault_agent, on every start.
--
-- The arms EXECUTE the real start_vault_agent, cut out of
-- images/git/entrypoint.sh by name, in the git image's own shell (the mirror's
-- production shell, which has inotifyd), with a stub agent bootstrap:
--   1 FAST     the stub writes the sink after 100 ms: ready within 400 ms
--              (red with the sleep loop: ~1000 ms)
--   2 RENAME   the stub writes a temp file and renames it into place: same
--   3 DEAD     the stub exits without a sink: refused at once, never "ready"
--   4 TIMEOUT  the stub never writes: refused after the 2 s hard timeout,
--              "timed out", and the stub is stopped
-- Without the git image (a host that never built it), every behaviour arm
-- SKIPS with that reason; a skip is never a pass.
--
-- Usage: tillandsias-plan script run scripts/lua/test-git-mirror-vault-sink-wait-is-an-event.lua
-- Verdict: ok:git-mirror-vault-sink-wait-is-an-event:<n> arms | skip:...:no-git-image | violation:...:<n>-failed

local NAME = "git-mirror-vault-sink-wait-is-an-event"
local ENTRY = "images/git/entrypoint.sh"
local IMAGE = env.get("TILLANDSIAS_GIT_IMAGE") or "localhost/tillandsias-git:latest"
local passed, failed = 0, {}
local function arm(name, cond, got)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local buf, inside = {}, false
for _, l in ipairs(text.lines(fs.read(ENTRY) or "")) do
    if not inside and l:find("^start_vault_agent%(%)%s*{") then inside = true end
    if inside then
        buf[#buf + 1] = l
        if l == "}" then break end
    end
end
local fn = table.concat(buf, "\n")
arm("0 premise: start_vault_agent was cut and waits on the token sink",
    #buf > 5 and fn:find("VAULT_TOKEN_FILE", 1, true) ~= nil and buf[#buf] == "}", #buf)

if proc.run{ argv = { "podman", "image", "exists", IMAGE } }.code ~= 0 then
    out.line("skip: " .. IMAGE .. " is not built on this host; behaviour arms not run")
    verdict.emit("skip:" .. NAME .. ":no-git-image", 0)
    return
end

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local REL = "target/plan-scratch/vault-sink-" .. tostring(time.now_ms())
local ABS = root .. "/" .. REL
fs.mkdir(REL)
fs.write(REL .. "/approle", "x\n")
-- the function reads a fixed AppRole path; point it at the scratch file
fs.write(REL .. "/fn.sh", (fn:gsub("/run/secrets/vault%-approle", "/f/approle")) .. "\n")
-- stub bootstrap: MODE selects how (or whether) the sink is written
fs.write(REL .. "/boot", table.concat({
    "#!/bin/bash",
    'case "$MODE" in',
    '  fast)   sleep 0.1; echo tok > "$VAULT_TOKEN_FILE"; sleep 30 ;;',
    '  rename) sleep 0.1; echo tok > "$VAULT_TOKEN_FILE.tmp"; mv "$VAULT_TOKEN_FILE.tmp" "$VAULT_TOKEN_FILE"; sleep 30 ;;',
    '  dead)   sleep 0.1; exit 3 ;;',
    '  silent) echo $$ > /f/silent.pid; sleep 30 ;;',
    'esac',
}, "\n") .. "\n")
fs.write(REL .. "/run.sh", table.concat({
    "#!/bin/bash",
    "export VAULT_TOKEN_FILE=/tmp/sinkdir/token",
    "mkdir -p /tmp/sinkdir",
    "VAULT_AGENT_BOOTSTRAP=/f/boot",
    "VAULT_AGENT_START_TIMEOUT=2",
    ". /f/fn.sh",
    "s=$(cut -d' ' -f1 /proc/uptime)",
    "start_vault_agent; rc=$?",
    "e=$(cut -d' ' -f1 /proc/uptime)",
    "ms=$(awk -v a=\"$s\" -v b=\"$e\" 'BEGIN{printf \"%d\", (b-a)*1000}')",
    "alive=gone",
    "[ -s /f/silent.pid ] && kill -0 \"$(cat /f/silent.pid)\" 2>/dev/null && alive=alive",
    "echo \"RESULT rc=$rc ms=$ms silent=$alive\"",
    "[ -n \"$VAULT_AGENT_PID\" ] && kill \"$VAULT_AGENT_PID\" 2>/dev/null",
    "exit 0",
}, "\n") .. "\n")
proc.run{ argv = { "chmod", "755", ABS .. "/boot", ABS .. "/run.sh" } }

local function launch(mode)
    proc.run{ argv = { "rm", "-f", ABS .. "/silent.pid" } }
    local r = proc.run{ argv = { "podman", "run", "--rm", "--network=none", "--security-opt", "label=disable",
        "-e", "MODE=" .. mode, "-v", ABS .. ":/f", "--entrypoint", "/bin/bash", IMAGE, "/f/run.sh" },
        timeout_ms = 60000 }
    local all = (r.stdout or "") .. (r.stderr or "")
    local rc, ms, silent = all:match("RESULT rc=(%d+) ms=(%d+) silent=(%a+)")
    return tonumber(rc), tonumber(ms), silent, all
end

local rc, ms, _, all = launch("fast")
arm("1 FAST: the sink written at 100 ms ends the wait within 400 ms",
    rc == 0 and ms and ms <= 400 and all:find("auto-auth ready", 1, true) ~= nil,
    "rc=" .. tostring(rc) .. " ms=" .. tostring(ms))

rc, ms, _, all = launch("rename")
arm("2 RENAME: a sink renamed into place ends the wait within 400 ms",
    rc == 0 and ms and ms <= 400, "rc=" .. tostring(rc) .. " ms=" .. tostring(ms))

rc, ms, _, all = launch("dead")
arm("3 DEAD: an agent that exits without a sink is refused at once, never ready",
    rc == 1 and ms and ms <= 1500 and all:find("exited before writing", 1, true) ~= nil
        and all:find("auto-auth ready", 1, true) == nil,
    "rc=" .. tostring(rc) .. " ms=" .. tostring(ms))

local silent
rc, ms, silent, all = launch("silent")
arm("4 TIMEOUT: an agent that never writes is refused at the 2 s hard timeout and stopped",
    rc == 1 and ms and ms >= 1900 and ms <= 4000 and all:find("timed out after 2s", 1, true) ~= nil
        and silent == "gone",
    "rc=" .. tostring(rc) .. " ms=" .. tostring(ms) .. " silent=" .. tostring(silent))

proc.run{ argv = { "rm", "-rf", ABS } }
if #failed > 0 then
    verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1)
else
    verdict.emit("ok:" .. NAME .. ":" .. passed .. " arms", 0)
end
