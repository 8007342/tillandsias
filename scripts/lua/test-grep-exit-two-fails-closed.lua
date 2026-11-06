-- @trace order:2007-vy3p, order:2006-wahn
-- @env PATH
--
-- test-grep-exit-two-fails-closed.lua — a push or credential gate whose grep
-- FAILS (exit 2: a pattern this grep rejects, or a file it cannot read) must
-- refuse, never pass.
--
-- Found on macOS (2006-wahn): pre-push-local-gate.sh's attestation-grammar ERE
-- began '^(|...', BSD grep rejected the empty alternative with exit 2, and
-- `if grep -qv` read that as "no bad line", so the plan-only lane admitted
-- every line. The arms:
--   1 FORM      the old form really fails open: `if grep -qvE '^(|x)$'` takes
--               the pass branch on this host's grep
--   2 HELPER    the hook's _grep_refuses refuses on a match AND on exit 2, and
--               passes only on a clean miss
--   3 WIRED     the hook's attestation-grammar check goes through _grep_refuses
--   4 PURGE     check-purge-clears-vault-credentials.sh reports an unreadable
--               purge script as a violation; the pre-fix form skipped it and
--               answered ok
--
-- Usage: tillandsias-plan script run scripts/lua/test-grep-exit-two-fails-closed.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("grep-exit-two-fails-closed", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/g2" .. tostring(math.random(1000, 9999))
fs.mkdir(REL)
local DIR = ROOT .. "/" .. REL
local HOOK = ROOT .. "/scripts/hooks/pre-push-local-gate.sh"
local PURGE = "scripts/check-purge-clears-vault-credentials.sh"

local failed, passed = {}, 0
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name .. (got and (" — " .. got) or ""))
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end
-- The script policy runs `bash <file>`, not `bash -c`, so each snippet is a file.
local nscript = 0
local function bash(script, cwd)
    nscript = nscript + 1
    local rel = REL .. "/s" .. nscript .. ".sh"
    fs.write(rel, script .. "\n")
    return proc.run({ argv = { "bash", ROOT .. "/" .. rel }, cwd = cwd or ROOT, timeout_ms = 60000 })
end

fs.write(REL .. "/bad-line", "prose that breaks the grammar\n")

-- 1: the old form takes the pass branch when grep cannot compile its pattern.
local r1 = bash("if LC_ALL=C grep -qvE '^(|x)$' '" .. DIR .. "/bad-line' 2>/dev/null; then echo refused; else echo passed; fi")
arm("1 FORM `if grep -qvE '^(|x)$'` takes the pass branch here (grep exit 2 read as a clean miss)",
    text.trim(r1.stdout or "") == "passed", text.trim(r1.stdout or ""))

-- 2: the helper, extracted from the hook and run for real.
local helper = "eval \"$(sed -n '/^_grep_refuses() {/,/^}/p' '" .. HOOK .. "')\"; "
local function verdict_of(args)
    local r = bash(helper .. "if _grep_refuses " .. args .. " 2>/dev/null; then echo refuse; else echo pass; fi")
    return text.trim(r.stdout or "")
end
local m = verdict_of("-qE 'prose' '" .. DIR .. "/bad-line'")
local miss = verdict_of("-qE 'nothing-like-this' '" .. DIR .. "/bad-line'")
local badpat = verdict_of("-qvE '^(|x)$' '" .. DIR .. "/bad-line'")
local unreadable = verdict_of("-qE 'x' '" .. DIR .. "/no-such-file'")
arm("2 HELPER _grep_refuses: match refuses, clean miss passes, bad pattern refuses, unreadable file refuses",
    m == "refuse" and miss == "pass" and badpat == "refuse" and unreadable == "refuse",
    "match=" .. m .. " miss=" .. miss .. " bad-pattern=" .. badpat .. " unreadable=" .. unreadable)

-- 3: the attestation-grammar check uses the helper.
local hook = fs.read(HOOK)
arm("3 WIRED the attestation-grammar check goes through _grep_refuses",
    hook:find("if _grep_refuses %-qvE '%^%(## %[0%-9%]") ~= nil
        and hook:find("grep %-qvE '%^%(|") == nil,
    "the hook's grammar line")

-- 4: the purge gate on a scratch repo with one unreadable purge script.
local repo = DIR .. "/repo"
local setup = table.concat({
    "set -e",
    "mkdir -p '" .. repo .. "/scripts'",
    "cp '" .. ROOT .. "/" .. PURGE .. "' '" .. repo .. "/scripts/'",
    "printf 'pub fn reset_state_once() -> i32 {\\n    keep();\\n}\\npub fn reset_guest_once() {}\\n' > '" .. repo .. "/soft.rs'",
    "printf '#!/bin/sh\\npodman system reset --force\\n' > '" .. repo .. "/scripts/wipe.sh'",
    "cd '" .. repo .. "' && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm fixture",
    "chmod 000 '" .. repo .. "/scripts/wipe.sh'",
}, "\n")
local s = bash(setup)
if s.code ~= 0 then
    arm("4 PURGE fixture", false, s.stderr)
else
    local function run_purge(script)
        local r = proc.run({
            argv = { "bash", script },
            cwd = repo,
            env = { PATH = env.get("PATH") or "/usr/bin:/bin", TILLANDSIAS_PURGE_GUARD_SOFT_SRC = repo .. "/soft.rs" },
            timeout_ms = 60000,
        })
        return text.trim(r.stdout or ""), r.code
    end
    local now, now_rc = run_purge("scripts/" .. PURGE:match("[^/]+$"))
    -- The pre-fix form, rebuilt from this file by undoing the fix, must answer ok.
    local pre = bash("sed -e 's/^    _rc=0; grep -qF -- \"\\$DESTROYS\" \"\\$f\" || _rc=\\$?$/    grep -qF -- \"$DESTROYS\" \"$f\" || continue/' " ..
        "-e 's/^    _rc=0; grep -qE \"^\\[^#\\]\\*\\${LINUX_DESTROYS}\" \"\\$f\" || _rc=\\$?$/    grep -qE \"^[^#]*${LINUX_DESTROYS}\" \"$f\" || continue/' " ..
        "-e '/^    case \"\\$_rc\" in 0) ;; 1) continue ;; \\*) violations+=/d' '" .. repo .. "/scripts/" .. PURGE:match("[^/]+$") .. "' > '" .. repo .. "/pre-fix.sh'")
    local before, before_rc = run_purge("pre-fix.sh")
    arm("4 PURGE an unreadable purge script is a violation now, and the pre-fix form answered ok",
        now_rc == 1 and now:find("scripts/wipe.sh:unreadable-grep-exit-2", 1, true) ~= nil
            and before_rc == 0 and before:find("^ok:purge%-clears%-vault%-credentials") ~= nil,
        "now rc=" .. tostring(now_rc) .. " [" .. now .. "]; pre-fix rc=" .. tostring(before_rc) .. " [" .. before .. "]" ..
            (pre.code ~= 0 and (" (pre-fix rebuild failed: " .. tostring(pre.stderr) .. ")") or ""))
end

bash("chmod -R u+rwx '" .. DIR .. "' 2>/dev/null; rm -rf '" .. DIR .. "'")
if #failed > 0 then
    verdict.emit("violation:grep-exit-two-fails-closed:" .. #failed .. "-failed", 1)
end
verdict.ok("grep-exit-two-fails-closed", passed .. " arms")
