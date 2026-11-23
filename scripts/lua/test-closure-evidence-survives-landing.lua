-- @trace order:1024-c3h3, order:2208-vxb6
--
-- test-closure-evidence-survives-landing.lua — PORTED from
-- test-closure-evidence-survives-landing.sh (2208-vxb6), same arms, same lines.
--
-- Pin: an evidence SHA that the landing rewrote must be NAMED, and the landed
-- commit offered in its place. The sanctioned closure order wrote
-- `set-field ... --evidence <sha>` BEFORE the land rewrote the commit, so the
-- recorded SHA never existed upstream (four of four closures on 2026-09-04).
--
-- The check must SEPARATE "captured too early" from "never landed" (arms 2
-- and 3), and must NOT flag a SHA that is reachable from the tip being pushed
-- (arm 4, the negative control): a host landing code and ledger in one push
-- cites exactly that.
--
-- HEAD: the checker runs in a scratch repo under target/plan-scratch with its
-- own origin, never against the real checkout's HEAD (2196-rdec: clean by
-- construction). The validator is resolved in the checkout and handed over
-- absolute, so no arm measures the checker's not-built skip.
--
-- Verdict: after the .sh's summary line, ok:closure-evidence-survives-landing:<p>
-- | violation:closure-evidence-survives-landing:<f> | skip:...:no-validator

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local CHECK = "scripts/lua/check-fragment-closure-evidence-added.lua"
local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) log.raw("FAIL: " .. m .. "\n"); fail = fail + 1 end
local function tailn(s, n)
    local ls = text.lines((s or ""):gsub("%s+$", ""))
    for i = math.max(1, #ls - n + 1), #ls do log.raw("      " .. ls[i] .. "\n") end
end

local rel = "target/plan-scratch/closure-evidence-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
local WC = W .. "/wc"
proc.run{ argv = { "mkdir", "-p", W } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end

-- Resolve the checkout's own binary HERE, where the probe can see it, and
-- EXECUTE it (the probe honours an explicit override on existence alone).
fs.write(rel .. "/resolve.sh", ". scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null\n")
local V = text.trim(proc.run{ argv = { "bash", W .. "/resolve.sh" } }.stdout or "")
if V:sub(1, 2) == "./" then V = root .. "/" .. V:sub(3) end
if V == "" then
    cleanup()
    log.raw("skip:closure-evidence-survives-landing:no-validator — no runnable tillandsias-plan in this checkout, so the arms would measure the checker's skip branch rather than the rule (build with ./build.sh to enable)\n")
    out.line("closure-evidence-survives-landing: 0 passed, 0 failed (skipped)")
    verdict.skip("closure-evidence-survives-landing:no-validator")
end

local GENV = { GIT_TERMINAL_PROMPT = "0" }
local function git(args)
    local a = { "git", "-c", "user.email=t@t", "-c", "user.name=t" }
    for _, x in ipairs(args) do a[#a + 1] = x end
    return proc.run{ argv = a, cwd = WC, env = GENV, timeout_ms = 120000 }
end
local function sha() return text.trim(git({ "rev-parse", "HEAD" }).stdout or "") end
local function put(path, body) fs.write(rel .. "/wc/" .. path, body) end
local function commit(msg) git({ "add", "-A" }); git({ "commit", "-q", "-m", msg }) end

proc.run{ argv = { "git", "init", "-q", "--bare", W .. "/bare.git" } }
proc.run{ argv = { "git", "init", "-q", "-b", "linux-next", WC } }
git({ "remote", "add", "origin", W .. "/bare.git" })
git({ "config", "core.hooksPath", ".git/hooks" })
git({ "config", "core.autocrlf", "false" })
proc.run{ argv = { "mkdir", "-p", WC .. "/scripts/lua", WC .. "/plan/index.d" } }
proc.run{ argv = { "cp", CHECK, WC .. "/scripts/lua/" } }
proc.run{ argv = { "cp", "scripts/plan-binary-probe.sh", WC .. "/scripts/" } }
proc.run{ argv = { "chmod", "+x", WC .. "/scripts/plan-binary-probe.sh" } }
put("README.md", "base\n")
commit("base")
git({ "push", "-q", "-u", "origin", "linux-next" })

local function frag(file, s)
    put("plan/index.d/" .. file, "packets:\n  - packet_id: fixture-packet\n    order: 9999-fixt\n    events:\n"
        .. "      - type: completed\n        ts: \"2026-09-05T00:00:00Z\"\n        host: fixture\n"
        .. "        summary: |\n          closed with evidence_refs: " .. s .. "\n")
end
local function run_check()
    local r = proc.run{ argv = { V, "script", "run", "scripts/lua/check-fragment-closure-evidence-added.lua" },
        cwd = WC, timeout_ms = 300000,
        env = { GIT_TERMINAL_PROMPT = "0", TILLANDSIAS_CLOSURE_EVIDENCE_BASE = "origin/linux-next",
            TILLANDSIAS_PLAN_BIN = V } }
    return (r.stdout or "") .. (r.stderr or "")
end

-- ── Reproduce the landing rewrite ──────────────────────────────────────────
git({ "checkout", "-q", "-b", "work" })
put("work.txt", "local work\n"); commit("the work commit")
local PRE = sha()
git({ "checkout", "-q", "linux-next" })
put("other.txt", "someone else\n"); commit("trunk moved")
git({ "push", "-q", "origin", "linux-next" })
git({ "checkout", "-q", "work" })
if not git({ "rebase", "-q", "linux-next" }).ok then
    cleanup()
    log.raw("SKIP: rebase unavailable\n")
    verdict.skip("closure-evidence-survives-landing:rebase-unavailable")
end
local POST = sha()
git({ "checkout", "-q", "linux-next" })
git({ "merge", "-q", "--ff-only", "work" })
git({ "push", "-q", "origin", "linux-next" })
if PRE ~= POST then
    ok("the landing really rewrote the commit (" .. PRE:sub(1, 7) .. " -> " .. POST:sub(1, 7) .. ")")
else bad("PRECONDITION: the rebase did not change the SHA; every arm below is vacuous") end

-- ── 1. THE GHOST: evidence captured before the rewrite ─────────────────────
frag("20260905t000001z-ghost.yaml", PRE)
commit("close with a pre-landing sha")
local o = run_check()
if o:find("evidence-ref-not-upstream: " .. PRE, 1, true) then ok("a pre-landing evidence SHA is named")
else bad("the ghost SHA was not flagged"); tailn(o, 5) end

-- ── 2. IT OFFERS THE LANDED COMMIT, which is what makes it correctable ─────
if o:find("same subject is " .. POST, 1, true) then ok("the landed commit with the same subject is named")
else bad("the landed candidate was not offered — a reader still cannot fix the ref") end

-- ── 3. THE OTHER DIAGNOSIS stays distinguishable ───────────────────────────
git({ "reset", "-q", "--hard", "origin/linux-next" })
proc.run{ argv = { "mkdir", "-p", WC .. "/plan/index.d" } }
git({ "checkout", "-q", "-b", "never-landed" })
put("never.txt", "never\n"); commit("a commit that never lands anywhere")
local NEVER = sha()
git({ "checkout", "-q", "linux-next" })
git({ "reset", "-q", "--hard", "origin/linux-next" })
proc.run{ argv = { "mkdir", "-p", WC .. "/plan/index.d" } }
frag("20260905t000002z-never.yaml", NEVER)
commit("close citing work that never landed")
local o2 = run_check()
if o2:find("No commit with that subject is on", 1, true) then
    ok("work that never landed is reported as the OTHER diagnosis")
else bad("a never-landed commit was not distinguished from a rewritten one"); tailn(o2, 6) end

-- ── 4. NEGATIVE CONTROL: a SHA in THIS push is not a ghost ────────────────
git({ "reset", "-q", "--hard", "origin/linux-next" })
proc.run{ argv = { "mkdir", "-p", WC .. "/plan/index.d" } }
put("inflight.txt", "in flight\n"); commit("code landing in this very push")
local INFLIGHT = sha()
frag("20260905t000003z-inflight.yaml", INFLIGHT)
commit("close citing the commit in this push")
local o3 = run_check()
if o3:find("evidence-ref-not-upstream: " .. INFLIGHT, 1, true) then
    bad("a commit reachable from the pushed tip was flagged as a ghost — this would red correct work")
else ok("a SHA reachable from the tip being pushed is not a ghost") end

cleanup()
out.line("closure-evidence-survives-landing: " .. pass .. " passed, " .. fail .. " failed")
if fail == 0 then verdict.ok("closure-evidence-survives-landing:" .. pass) end
verdict.emit("violation:closure-evidence-survives-landing:" .. fail, 1)
