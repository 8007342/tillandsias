-- @trace order:1267-uafx, order:2209-jw2t
-- inputs: scripts/hooks/pre-push-local-gate.sh scripts/plan-binary-probe.sh scripts/gate-stamp.sh scripts/common.sh scripts/check-issue-citation-convention.sh lib/lua/common/ crates/tillandsias-plan/ Cargo.lock plan/index.yaml scripts/lua/check-fragment-status-loss.lua
--
-- test-plan-binary-remedy-names-only-a-runnable-binary.lua — PORTED from
-- test-plan-binary-remedy-names-only-a-runnable-binary.sh (2209-jw2t), same
-- arms, same lines.
--
-- The pre-push plan-only lane, on refusing a STALE plan binary, looks for a
-- FRESHER build of the same binary and prints it as the remedy:
--   REMEDY: TILLANDSIAS_PLAN_BIN=<candidate> git push ...
-- It chose that candidate by MTIME ALONE; on a shared Windows/WSL checkout the
-- WSL gate leaves a Linux ELF beside the .exe, newer than it, which exits 126
-- on the Windows side, and the hook recommended it verbatim (yolanda
-- 2026-09-19). 704-zcgi: an executable bit is a claim; RUNNING it is evidence.
--
-- Drives the REAL hook against a scratch checkout (under target/plan-scratch,
-- its own origin: never the real checkout's HEAD — 2196-rdec, clean by
-- construction). The unrunnable candidate is BUILT HERE — ELF magic, +x — so
-- every arm runs on every host.
--
--   ARM 1  NEGATIVE: only a newer UNRUNNABLE candidate → the remedy must NOT
--          name it, and the lane falls back to the rebuild remedy.
--   ARM 2  POSITIVE: a newer RUNNABLE candidate → it IS named.
--   ARM 3  THE WINDOWS SHAPE: a newer unrunnable ELF AND a newer runnable .exe
--          → the .exe is named and the ELF is not.
-- Every arm first asserts the lane REFUSED as stale.
--
-- Verdict: ok:plan-binary-remedy-runnable:<n> | fail:plan-binary-remedy-runnable

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local pass, fail = 0, 0
local function ck(desc, want, got)
    if want == got then out.line("  ok   " .. desc); pass = pass + 1
    else out.line("  FAIL " .. desc .. " (expected " .. want .. ", got " .. got .. ")"); fail = fail + 1 end
end
local function has(s, p) if s:find(p, 1, true) then return "yes" end return "no" end

local rel = "target/plan-scratch/plan-remedy-runnable-" .. tostring(time.now_ms())
local LW = root .. "/" .. rel
local WC = LW .. "/wc"
proc.run{ argv = { "mkdir", "-p", LW } }
local function cleanup() proc.run{ argv = { "find", LW, "-delete" }, timeout_ms = 60000 } end
local function sh(cmd_file, ...) -- run a helper FILE (argv, never a shell string)
    local a = { "bash", LW .. "/" .. cmd_file }
    for _, x in ipairs({ ... }) do a[#a + 1] = x end
    return proc.run{ argv = a, timeout_ms = 60000 }
end
local function LG(args)
    local a = { "git", "-C", WC, "-c", "user.email=t@t", "-c", "user.name=t" }
    for _, x in ipairs(args) do a[#a + 1] = x end
    return proc.run{ argv = a, timeout_ms = 60000 }
end

proc.run{ argv = { "git", "init", "-q", "--bare", LW .. "/bare.git" } }
proc.run{ argv = { "git", "init", "-q", "-b", "linux-next", WC } }
LG({ "remote", "add", "origin", LW .. "/bare.git" })
LG({ "config", "core.hooksPath", ".git/hooks" })
proc.run{ argv = { "mkdir", "-p", WC .. "/scripts/hooks", WC .. "/plan/index.d", WC .. "/crates/tillandsias-plan/src",
    WC .. "/target/release", WC .. "/target/debug", WC .. "/scripts/lua" } }
proc.run{ argv = { "cp", "scripts/hooks/pre-push-local-gate.sh", WC .. "/scripts/hooks/" } }
for _, f in ipairs({ "plan-binary-probe.sh", "gate-stamp.sh", "common.sh", "check-issue-citation-convention.sh" }) do
    if fs.exists("scripts/" .. f) then proc.run{ argv = { "cp", "scripts/" .. f, WC .. "/scripts/" } } end
end
-- ORDER 1570-mxcg: the status-loss guard is Lua; the lane runs it from scripts/lua/.
if fs.exists("scripts/lua/check-fragment-status-loss.lua") then
    proc.run{ argv = { "cp", "scripts/lua/check-fragment-status-loss.lua", WC .. "/scripts/lua/" } }
end
if not fs.exists(rel .. "/wc/scripts/plan-binary-probe.sh") then
    cleanup(); verdict.emit("fail:plan-remedy-runnable:setup:probe-not-copied", 1)
end
proc.run{ argv = { "find", WC .. "/scripts", "-name", "*.sh", "-exec", "chmod", "+x", "{}", "+" } }
fs.write(rel .. "/wc/plan/index.yaml", "packets: []\n")
fs.write(rel .. "/wc/crates/tillandsias-plan/src/main.rs", "fn main() {}\n")
fs.write(rel .. "/wc/Cargo.lock", "# lock\n")

local STUB = [[#!/usr/bin/env bash
case "${1:-}" in
    capabilities) echo compact; exit 0 ;;
    check) exit 0 ;;
    validate-yaml) exit 0 ;;
    yaml-type) echo '!!map'; exit 0 ;;
esac
exit 0
]]
local function runnable_stub(r) fs.write(r, STUB); proc.run{ argv = { "chmod", "+x", root .. "/" .. r } } end
local function unrunnable_elf(r) -- ELF magic and nothing else
    fs.write(r, "\127ELF\002\001\001\000"); proc.run{ argv = { "chmod", "+x", root .. "/" .. r } }
end

runnable_stub(rel .. "/wc/target/release/tillandsias-plan")
LG({ "add", "-A" }); LG({ "commit", "-q", "-m", "base" })
proc.run{ argv = { "git", "push", "-q", "-u", "origin", "linux-next" }, cwd = WC }
fs.write(rel .. "/wc/plan/index.d/20260923t000000z-remedy-arm.yaml", "packets: []\n")
LG({ "add", "-A" }); LG({ "commit", "-q", "-m", "a fragment push" })

local function lane_push()
    local head = text.trim(LG({ "rev-parse", "HEAD" }).stdout or "")
    local up = text.trim(LG({ "rev-parse", "origin/linux-next" }).stdout or "")
    local r = proc.run{ argv = { "env", "-u", "TILLANDSIAS_PLAN_BIN", "-u", "CARGO_TARGET_DIR",
            "bash", "scripts/hooks/pre-push-local-gate.sh", "origin", LW .. "/bare.git" },
        cwd = WC, stdin = "refs/heads/linux-next " .. head .. " refs/heads/linux-next " .. up .. "\n",
        timeout_ms = 300000 }
    return (r.stdout or "") .. (r.stderr or ""), r.code
end
-- The resolved binary (release, runnable) is stale against the sources; every
-- candidate planted per arm is NEWER than it.
local function reset_arm()
    for _, f in ipairs({ "target/debug/tillandsias-plan", "target/debug/tillandsias-plan.exe",
            "target/release/tillandsias-plan.exe" }) do
        proc.run{ argv = { "find", WC .. "/" .. f:match("^(.*)/"), "-maxdepth", "1", "-name", f:match("([^/]+)$"), "-delete" } }
    end
    proc.run{ argv = { "touch", "-t", "202609041215", WC .. "/target/release/tillandsias-plan" } }
    proc.run{ argv = { "touch", "-t", "202609111933", WC .. "/crates/tillandsias-plan/src/main.rs", WC .. "/Cargo.lock" } }
end
local function newer(...)
    local a = { "touch", "-t", "202609221200" }
    for _, x in ipairs({ ... }) do a[#a + 1] = WC .. "/" .. x end
    proc.run{ argv = a }
end

-- Helpers, as FILES: exec a candidate the way bash does (126 on a bad
-- binary), and the probe's own runnability rule.
fs.write(rel .. "/exec-rc.sh", '"$1" --help >/dev/null 2>&1; echo $?\n')
fs.write(rel .. "/runs.sh", '. "$1/scripts/plan-binary-probe.sh"; cd "$2" && target_binary_runs "$3"\n')

-- The unrunnable candidate must really be unrunnable HERE.
unrunnable_elf(rel .. "/elf-probe")
local prc = text.trim(sh("exec-rc.sh", LW .. "/elf-probe").stdout or "")
if prc == "126" or prc == "127" then ck("premise: the planted ELF does not run on this host (rc " .. prc .. ")", "yes", "yes")
else ck("premise: the planted ELF does not run on this host (rc " .. prc .. ")", "yes", "no") end

-- ── ARM 1 — NEGATIVE ────────────────────────────────────────────────────────
reset_arm()
unrunnable_elf(rel .. "/wc/target/debug/tillandsias-plan"); newer("target/debug/tillandsias-plan")
local o, rc = lane_push()
ck("arm1: the lane refuses the stale binary", "1", tostring(rc))
ck("arm1: the refusal names STALENESS", "yes", has(o, "is STALE"))
ck("arm1: the unrunnable newer ELF is NOT named as a remedy", "no", has(o, "TILLANDSIAS_PLAN_BIN=./target/debug/tillandsias-plan "))
ck("arm1: no FRESHER line at all", "no", has(o, "A FRESHER build"))
ck("arm1: falls back to the rebuild remedy", "yes", has(o, "cargo build --release -p tillandsias-plan"))

-- ── ARM 2 — POSITIVE ────────────────────────────────────────────────────────
reset_arm()
runnable_stub(rel .. "/wc/target/debug/tillandsias-plan.exe"); newer("target/debug/tillandsias-plan.exe")
o, rc = lane_push()
ck("arm2: the lane refuses the stale binary", "1", tostring(rc))
-- Assert on what the remedy DOES, not its spelling (MINGW names the
-- extensionless path for the .exe).
local named = ""
for _, l in ipairs(text.lines(o)) do
    local m = l:match("REMEDY: TILLANDSIAS_PLAN_BIN=([^ ]*) git push")
    if m and named == "" then named = m end
end
if named == "./target/debug/tillandsias-plan" or named == "./target/debug/tillandsias-plan.exe" then
    ck("arm2: a newer candidate IS named (" .. named .. ")", "yes", "yes")
else ck("arm2: a newer candidate IS named (" .. (named ~= "" and named or "none") .. ")", "yes", "no") end
local nrc = 1
if named ~= "" then nrc = sh("runs.sh", root, WC, named).code end
ck("arm2: the named remedy binary RUNS", "0", tostring(nrc))

-- ── ARM 3 — THE WINDOWS SHAPE ───────────────────────────────────────────────
reset_arm()
unrunnable_elf(rel .. "/wc/target/debug/tillandsias-plan")
runnable_stub(rel .. "/wc/target/debug/tillandsias-plan.exe")
newer("target/debug/tillandsias-plan", "target/debug/tillandsias-plan.exe")
o, rc = lane_push()
ck("arm3: the lane refuses the stale binary", "1", tostring(rc))
ck("arm3: the runnable .exe is named", "yes", has(o, "TILLANDSIAS_PLAN_BIN=./target/debug/tillandsias-plan.exe git push"))
ck("arm3: the unrunnable ELF beside it is NOT named", "no", has(o, "TILLANDSIAS_PLAN_BIN=./target/debug/tillandsias-plan git push"))

cleanup()
out.line("plan-binary-remedy-runnable: " .. pass .. " passed, " .. fail .. " failed")
if fail == 0 then verdict.emit("ok:plan-binary-remedy-runnable:" .. pass, 0) end
verdict.emit("fail:plan-binary-remedy-runnable", 1)
