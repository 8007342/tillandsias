-- @trace order:1443-we89, order:1750-a4re, order:2400-prg4, spec:command-policies
-- @env PATH HOME TMPDIR
--
-- test-pretooluse-command-policy.lua — the Bash-tool bridge, driven with hook JSON exactly
-- as Claude Code sends it, so it never needs the hook installed. Ported from
-- test-pretooluse-command-policy.sh (2400-prg4); same arms, in its order.
--
--   1  an unquoted heredoc carrying a backtick is refused (why + remedy)
--   2  pipefail + `| grep -q`, and a check-/test- script `| tail -1`, are refused
--   3  gh auth refresh / login / token are refused
--   4  destructive classes ask (the permissionDecision JSON), never allow; a soft reset
--      follows the policy engine (allowed in a forge, asked elsewhere)
--   5  a shell string with a pipe or $( ) crossing a boundary is refused
--   6  NEGATIVE CONTROL: ordinary commands, a QUOTED heredoc with backticks and a pipeline
--      with no pipefail and no verdict consumer all allow, silently
--   7  --status prints the counts and the three-part retirement condition; the kill switch
--      allows everything and is logged
--   8  the stub is under sixty lines and bash-dialect clean; no runnable binary allows
--   9  the wiring: repo settings, the forge overlay, and the forge seed merge (needs jq)
--  10  a binary that RUNS but predates classify-bash allows, not denies
--
-- Every command below is DATA: it is fed to the hook as JSON or to `policy classify-bash` /
-- `policy eval` as a string. None is executed.
--
-- GRAMMAR ok:pretooluse-command-policy:<n> arms | violation:pretooluse-command-policy:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("pretooluse-command-policy")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local STUB_REL = "scripts/hooks/claude-pretooluse-command-policy.sh"
if not fs.exists(STUB_REL) then T:refuse("stub-absent", STUB_REL) end
local STUB = ROOT .. "/" .. STUB_REL
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-runnable-plan-binary", "the bridge execs it") end
-- is_abs: a native Windows drive path C:/x is absolute too (yolanda msys, #1627).
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end

local W = T:scratch()
local AUDIT = W.abs .. "/decisions.jsonl"
local AUDIT_REL = W.rel .. "/decisions.jsonl"
local UNSET = { "TILLANDSIAS_*" }
local TMPD = (env.get("TMPDIR") or ""); if TMPD == "" then TMPD = "/tmp" end
TMPD = TMPD:gsub("/$", "")
local BASE = { TILLANDSIAS_POLICY_AUDIT_LOG = AUDIT, TILLANDSIAS_PLAN_BIN = PLAN, TMPDIR = TMPD }
local function with(extra)
    local e = {}
    for k, v in pairs(BASE) do e[k] = v end
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
end

local function json_str(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\t", "\\t")
    return '"' .. s .. '"'
end
local function lines_has(s, want) for _, l in ipairs(text.lines(s)) do if l == want then return true end end return false end
local function has(s, p) return s:find(p, 1, true) ~= nil end
local function starts_line(s, p) for _, l in ipairs(text.lines(s)) do if l:sub(1, #p) == p then return true end end return false end

local function hook(cmd, tool, extra_env)
    local input = string.format('{"session_id":"fixture","hook_event_name":"PreToolUse","tool_name":"%s","cwd":%s,"tool_input":{"command":%s}}',
        tool or "Bash", json_str(ROOT), json_str(cmd))
    local r = T:run{ SH, STUB, cwd = ROOT, stdin = input, env = with(extra_env), env_unset = UNSET, timeout_ms = 60000 }
    return r.code, text.trim(r.stdout or ""), text.trim(r.stderr or "")
end
local function expect_deny(label, token, cmd, ...)
    local rc, out, err = hook(cmd)
    local good = rc == 2 and out == "" and lines_has(err, "refused:bash-policy:" .. token)
        and starts_line(err, "why: ") and starts_line(err, "remedy: ")
    for _, r in ipairs{ ... } do if not has(err, r) then good = false end end
    T:arm(label, good, "rc=" .. tostring(rc) .. " out=[" .. out .. "] err=[" .. err .. "]")
end
local function jget(args, input)
    local argv = { PLAN, "json", "get" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    argv.cwd, argv.stdin, argv.env_unset, argv.timeout_ms = ROOT, input, UNSET, 30000
    return text.trim(T:run(argv).stdout or "")
end
local function expect_ask(label, class, cmd)
    local rc, out, err = hook(cmd)
    local good = rc == 0 and jget({ "-r", ".hookSpecificOutput.permissionDecision" }, out) == "ask"
        and jget({ "-r", ".hookSpecificOutput.hookEventName" }, out) == "PreToolUse"
        and has(out, "consent class: " .. class)
    T:arm(label, good, "rc=" .. tostring(rc) .. " out=[" .. out .. "] err=[" .. err .. "]")
end
local function expect_allow(label, cmd, tool)
    local rc, out, err = hook(cmd, tool)
    T:arm(label, rc == 0 and out == "" and err == "", "rc=" .. tostring(rc) .. " out=[" .. out .. "] err=[" .. err .. "]")
end
local function classify(cmd, extra, envx)
    local argv = { PLAN, "policy", "classify-bash", "--command", cmd }
    for _, a in ipairs(extra or {}) do argv[#argv + 1] = a end
    argv.cwd, argv.env, argv.env_unset, argv.timeout_ms = ROOT, with(envx), UNSET, 30000
    local r = T:run(argv)
    return r.code, text.trim(r.stdout or "")
end

-- 1
expect_deny("arm 1: unquoted heredoc with a backtick span is refused", "unquoted-heredoc-executes-prose",
    "cat > note.md <<EOF\nrun `openspec init` first\nEOF", "<<'EOF'", "tillandsias-plan run --stdin-file")

-- 2
expect_deny("arm 2: pipefail + grep -q verdict pipeline is refused", "sigpipe-verdict-pipeline",
    "set -o pipefail; git log --oneline | grep -q fix && echo yes", "run --json", 'grep -q PAT <<<"$')
expect_deny("arm 2: a check script's verdict through tail -1 is refused", "verdict-through-tail",
    "bash scripts/check-bash-dialect.sh | tail -1")

-- 3
for _, sub in ipairs{ "refresh", "login", "token" } do
    expect_deny("arm 3: gh auth " .. sub .. " is refused", "no-credential-mutation", "gh auth " .. sub)
end

-- 4
expect_ask("arm 4: rm -rf outside the working dir, TMPDIR and scratch asks", "workspace-destroy", "rm -rf /etc/some-dir")
expect_ask("arm 4: a force-push to linux-next asks", "force-push", "git push --force origin linux-next")
-- Soft resets follow the policy engine's own host-kind reading (a forge needs physical evidence).
local sr = T:run{ PLAN, "policy", "eval", "--", "tillandsias", "--reset-state", cwd = ROOT, env = with(), env_unset = UNSET, timeout_ms = 30000 }
local soft = text.lines(sr.stdout or "")[1] or ""
for _, cmd in ipairs{ "podman system reset --force", "tillandsias --reset-state" } do
    if soft == "ok:policy:soft-reset:forge-preauthorised" then
        expect_allow("arm 4: '" .. cmd .. "' is a soft reset, pre-authorised in this forge", cmd)
    else
        expect_ask("arm 4: '" .. cmd .. "' asks on this host (soft reset)", "soft-reset", cmd)
    end
    local rc, out = classify(cmd, { "--host-kind", "bare-metal" })
    T:arm("arm 4: '" .. cmd .. "' asks on bare metal, never allows", rc == 4 and lines_has(out, "consent:bash-policy:soft-reset"),
        "rc=" .. tostring(rc) .. " [" .. out .. "]")
end
-- Scratch: paths BENEATH /tmp and $TMPDIR need no consent; the ROOTS themselves still ask.
for _, t in ipairs{ "/tmp/pretooluse-scratch-x", TMPD .. "/pretooluse-scratch-y" } do
    local rc, out = classify("rm -rf " .. t, { "--cwd", ROOT })
    T:arm("arm 4: rm -rf " .. t .. " (beneath a scratch root) needs no consent", rc == 0, "rc=" .. tostring(rc) .. " [" .. out .. "]")
end
for _, t in ipairs{ "/tmp", "/private/tmp", TMPD } do
    local rc, out = classify("rm -rf " .. t, { "--cwd", ROOT })
    T:arm("arm 4 NEGATIVE: rm -rf " .. t .. " (a scratch ROOT itself) asks",
        rc == 4 and lines_has(out, "consent:bash-policy:workspace-destroy"), "rc=" .. tostring(rc) .. " [" .. out .. "]")
end
-- A variable target is expanded from the environment, and one it cannot resolve asks.
local rch, outh = classify('rm -rf "$HOME"', { "--cwd", ROOT }, { HOME = "/home/nobody-fixture" })
T:arm('arm 4: rm -rf "$HOME" is judged as the expanded path, and asks', rch == 4, "rc=" .. tostring(rch) .. " [" .. outh .. "]")
-- An unresolvable target is REFUSED with a remedy, never asked (2026-09-28).
expect_deny("arm 4: an rm target with an unset variable is refused with a remedy, not asked",
    "unresolvable-rm-target", 'rm -rf "$PRETOOLUSE_UNSET_X/y"', "literal path")
expect_deny("arm 4: the operator's shape (a mktemp dir deleted through its variable) is refused, not asked",
    "unresolvable-rm-target", 'd=$(mktemp -d); ls "$d"; rm -rf $d', "literal path")
local rct, outt = classify('rm -rf "${TMPDIR:-/tmp}/pretooluse-z"', { "--cwd", ROOT })
T:arm('arm 4: rm -rf "${TMPDIR:-/tmp}/…" expands and needs no consent', rct == 0, "rc=" .. tostring(rct) .. " [" .. outt .. "]")

-- 5
expect_deny("arm 5: wsl.exe … bash -lc with a pipe is refused", "string-crosses-a-boundary", 'wsl.exe -d x -- bash -lc "a | b"')
expect_deny('arm 5: bash -c "$(cat f)" is refused', "string-crosses-a-boundary", 'bash -c "$(cat f)"')

-- 6: NEGATIVE CONTROL
expect_allow("arm 6: git status allows", "git status")
expect_allow("arm 6: ls -la /tmp allows", "ls -la /tmp")
expect_allow("arm 6: a QUOTED heredoc with backticks allows", "cat > note.md <<'EOF'\nrun `openspec init` first\nEOF")
expect_allow("arm 6: printf | sort with no pipefail and no verdict consumer allows", 'printf %s "$x" | sort')
expect_allow("arm 6: a plain bash -c string allows (unknown shapes allow)", 'bash -c "echo hi"')
expect_allow("arm 6: a non-Bash tool is not this bridge's business", "rm -rf /", "Write")

-- 7
local st = T:run{ SH, STUB, "--status", cwd = ROOT, env = with(), env_unset = UNSET, timeout_ms = 60000 }
local status = st.stdout or ""
local dec = false
for _, l in ipairs(text.lines(status)) do if l:match("^decisions=%d+/%d+/%d+ ") then dec = true end end
T:arm("arm 7: --status prints decisions=<d>/<a>/<al> and the three-part retirement condition",
    st.code == 0 and dec and has(status, "(a) 1443-8pur and 1443-r4cj are closed on every locus")
        and has(status, "(b) the audit shows zero deny and zero ask decisions from caller=pretooluse for 14 consecutive fleet days")
        and has(status, "(c) the operator flips the Bash tool's default"),
    "rc=" .. tostring(st.code) .. " [" .. status .. "]")
local krc, kout = hook("gh auth refresh", "Bash", { TILLANDSIAS_PRETOOLUSE_HOOK = "off" })
local log = fs.read(AUDIT_REL) or ""
T:arm("arm 7: the kill switch allows a deny-shaped command and logs kill_switch=1",
    krc == 0 and kout == "" and has(log, '"kill_switch":1'), "rc=" .. tostring(krc) .. " out=[" .. kout .. "]")
T:arm("arm 7: the decision log never records the raw command", not has(log, "openspec"), "the decision log recorded a raw command")

-- 8
local stub_text = fs.read(STUB_REL) or ""
local n = #text.lines(stub_text)
if stub_text:sub(-1) == "\n" and text.lines(stub_text)[n] == "" then n = n - 1 end
local dr = T:run{ PLAN, "script", "run", ROOT .. "/scripts/lua/check-bash-dialect.lua", cwd = ROOT,
    env = { TILLANDSIAS_DIALECT_SCAN_DIR = STUB }, env_unset = { "TILLANDSIAS_REPO_ROOT", "PROJECT_ROOT" }, timeout_ms = 60000 }
local dialect = text.trim(dr.stdout or "")
T:arm("arm 8: the stub is " .. n .. " lines and bash-dialect clean", n < 60 and dialect == "ok:bash-dialect-clean",
    "lines=" .. n .. " dialect=[" .. dialect .. "]")
local nb = T:run{ SH, STUB, cwd = ROOT, stdin = '{"tool_name":"Bash","tool_input":{"command":"gh auth refresh"}}',
    env = with{ TILLANDSIAS_PLAN_BIN = W.abs .. "/not-runnable" }, env_unset = UNSET, timeout_ms = 60000 }
T:arm("arm 8: with no runnable plan binary the bridge allows, with a note",
    nb.code == 0 and text.trim(nb.stdout or "") == "" and starts_line(nb.stderr or "", "note:pretooluse:no-plan-binary"),
    "rc=" .. tostring(nb.code) .. " [" .. (nb.stdout or "") .. "] [" .. (nb.stderr or "") .. "]")

-- 9: the wiring (operator ruling 1: commit the hook to the project)
local function jfile(args, file) local a = {}; for _, x in ipairs(args) do a[#a + 1] = x end; a[#a + 1] = file; return jget(a) end
local repo_cmd = jfile({ "-r", ".hooks.PreToolUse[0].hooks[0].command" }, ROOT .. "/.claude/settings.json")
local repo_match = jfile({ "-r", ".hooks.PreToolUse[0].matcher" }, ROOT .. "/.claude/settings.json")
T:arm("arm 9: .claude/settings.json runs the stub for Bash, anchored on $CLAUDE_PROJECT_DIR (any mount prefix)",
    repo_match == "Bash" and repo_cmd == '"$CLAUDE_PROJECT_DIR"/scripts/hooks/claude-pretooluse-command-policy.sh',
    "matcher=[" .. repo_match .. "] command=[" .. repo_cmd .. "]")
local OVERLAY = ROOT .. "/images/default/config-overlay/claude/settings.json"
local ov_cmd = jfile({ "-r", ".hooks.PreToolUse[0].hooks[0].command" }, OVERLAY)
T:arm("arm 9: the forge overlay runs the image's fail-closed hook by absolute path (projects without the stub; 1750-a4re)",
    jfile({ "-r", ".hooks.PreToolUse[0].matcher" }, OVERLAY) == "Bash" and ov_cmd == "/usr/local/lib/tillandsias/bash-policy-hook",
    "overlay command=[" .. ov_cmd .. "]")
if fixture.which("jq") then
    -- The seed is a bash function in lib-common.sh; it runs through a harness file, as the .sh
    -- eval'd it (proc.run has no `bash -c`).
    fs.mkdir(W.rel .. "/overlay/claude"); fs.mkdir(W.rel .. "/home/.claude")
    fs.write(W.rel .. "/overlay/claude/settings.json", fs.read("images/default/config-overlay/claude/settings.json") or "")
    fs.write(W.rel .. "/seed.sh", table.concat({
        'trace_lifecycle() { :; }',
        'eval "$(sed -n \'/^seed_claude_pretooluse_hook()/,/^}/p\' "$1/images/default/lib-common.sh")"',
        'seed_claude_pretooluse_hook', "" }, "\n"))
    local SETTINGS = W.abs .. "/home/.claude/settings.json"
    local SETTINGS_REL = W.rel .. "/home/.claude/settings.json"
    local function seed(kind)
        return T:run{ SH, W.abs .. "/seed.sh", ROOT, cwd = ROOT, env_unset = UNSET, timeout_ms = 60000,
            env = { TILLANDSIAS_HOST_KIND = kind, TILLANDSIAS_CONFIG_OVERLAY_ROOT = W.abs .. "/overlay", CLAUDE_SETTINGS_FILE = SETTINGS } }
    end
    fs.write(SETTINGS_REL, '{"skipDangerousModePermissionPrompt":true,"hooks":{"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"true"}]}]}}\n')
    seed("forge"); seed("forge")
    local got = jfile({ "-c", "[.skipDangerousModePermissionPrompt, .hooks.PostToolUse[0].matcher, .hooks.PreToolUse[0].hooks[0].command]" }, SETTINGS)
    local _, copies = (fs.read(SETTINGS_REL) or ""):gsub("bash%-policy%-hook", "")
    T:arm("arm 9: the forge seed merges the hook once, keeping every other setting and hook",
        got == '[true,"Edit","/usr/local/lib/tillandsias/bash-policy-hook"]' and copies == 1, "got=[" .. got .. "] copies=" .. copies)
    -- 1750-a4re: a restored pre-1750 bare command is migrated; another PreToolUse hook is kept.
    fs.write(SETTINGS_REL, '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"tillandsias-plan policy classify-bash --hook"}]},{"matcher":"Edit","hooks":[{"type":"command","command":"true"}]}]}}\n')
    seed("forge")
    got = jfile({ "-c", "[.hooks.PreToolUse[].hooks[0].command]" }, SETTINGS)
    T:arm("arm 9: a restored pre-1750 bare classify-bash entry is replaced by the image hook; other PreToolUse hooks are kept",
        got == '["true","/usr/local/lib/tillandsias/bash-policy-hook"]', "got=[" .. got .. "]")
    T:must{ "rm", "-f", SETTINGS }
    seed("")
    T:arm("arm 9: outside a forge the seed writes nothing", not fs.exists(SETTINGS_REL), "non-forge seed wrote " .. SETTINGS)
else
    out.line("note:pretooluse-command-policy:no-jq — the forge seed arm needs jq (it ships in the forge image)")
end

-- 10: a binary that RUNS but predates `classify-bash` must ALLOW, not deny (land83 relay).
fs.write(W.rel .. "/stale-plan", table.concat({ "#!/usr/bin/env bash",
    '[ "${1:-}" = capabilities ] && { echo policy; exit 0; }',
    'echo "usage: tillandsias-plan policy eval [...] -- <argv...>" >&2', "exit 2", "" }, "\n"))
T:must{ "chmod", "+x", W.abs .. "/stale-plan" }
local s10 = T:run{ SH, STUB, cwd = ROOT, stdin = '{"tool_name":"Bash","tool_input":{"command":"git status"}}',
    env = with{ TILLANDSIAS_PLAN_BIN = W.abs .. "/stale-plan" }, env_unset = UNSET, timeout_ms = 60000 }
T:arm("arm 10: a plan binary that predates classify-bash is allowed with a note, not read as a deny",
    s10.code == 0 and text.trim(s10.stdout or "") == "" and has(s10.stderr or "", "note:pretooluse:could-not-classify:rc=2"),
    "rc=" .. tostring(s10.code) .. " out=[" .. (s10.stdout or "") .. "] err=[" .. (s10.stderr or "") .. "]")

T:finish()
