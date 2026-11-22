-- @trace order:1309-qc95, order:2237-f9b6, spec:git-mirror-service
-- @env TILLANDSIAS_TEST_SSH_LANE_HOLD
-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-ssh-lane-refuses-when-unwired.lua — PORTED from
-- test-ssh-lane-refuses-when-unwired.sh (2237-f9b6). Pins that the
-- AUTHENTICATED ssh push lane REFUSES when it is enabled but its host-CA cache
-- is absent, instead of falling open to the anonymous git:// path (1309-qc95):
-- the generated gitconfig must carry a pushInsteadOf to an unroutable url and
-- say "Pushes REFUSE", never "Pushes fall back to the anonymous mirror
-- redirect". Omitting the push redirect is NOT the fix: the anonymous
-- insteadOf written earlier covers push too.
--
--   1 the behavioural unit arms (cargo test write_forge_gitconfig) pass on
--     the checkout's source, which this fixture only READS
--   2 MUTATION: the pre-fix wording, put back into a SCRATCH WORKTREE's copy
--     of main.rs (never the checkout's), reds the same unit arms there; the
--     mutation is checked present before any test result counts
--   3 KILLED MID-ARM: arm 2 run as a child (TILLANDSIAS_TEST_SSH_LANE_HOLD)
--     is SIGKILLed after its mutation applied; the checkout's tracked files
--     are still clean (git status) and its main.rs still says Pushes REFUSE
--
-- WHY A WORKTREE, NOT A TRAP (2237-f9b6). The .sh mutated the live main.rs
-- and restored it from `trap restore EXIT INT TERM`. SIGKILL (a gate
-- deadline, an OOM kill) runs no trap, so a killed gate left the source
-- mutated, and the cargo test raced any other cargo in the same tree. Here
-- the checkout's source is never written. The worktree shares the checkout's
-- target dir, so only the workspace crates rebuild; the preflight door sweeps
-- a worktree registration a KILL leaves behind (1600-nn5b).
--
-- Verdict: ok:ssh-lane-refuses-when-unwired:<n> after the .sh's
-- `ok: ssh-lane-refuses-when-unwired PASS` line (the litmus reads it), or
-- violation:ssh-lane-refuses-when-unwired:<failed>.

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local SRC = "crates/tillandsias-headless/src/main.rs"
local HOLD = env.get("TILLANDSIAS_TEST_SSH_LANE_HOLD")
local FIXED = "Pushes REFUSE. The anonymous mirror redirect above is NOT used in their"
-- Built by concatenation so this fixture does not itself contain the literal
-- string its own guard forbids (1287-myx8).
local PRE_FIX = "Pushes fall " .. "back to the anonymous mirror redirect"

local function read(path)
    return proc.run{ argv = { "cat", path } }.stdout or ""
end
if read(root .. "/" .. SRC) == "" then
    verdict.emit("skip:ssh-lane-refuses-when-unwired:" .. SRC .. " absent", 3)
end

local function unit_arms(manifest)
    local argv = { "cargo", "test", "--quiet", "-p", "tillandsias-headless", "--bin", "tillandsias" }
    if manifest then argv[#argv + 1] = "--manifest-path"; argv[#argv + 1] = manifest end
    argv[#argv + 1] = "write_forge_gitconfig"
    local p = proc.run{ argv = argv, env = { CARGO_TARGET_DIR = root .. "/target" }, timeout_ms = 1800000 }
    return p.code, (p.stdout or "") .. (p.stderr or "")
end

-- A scratch worktree carrying the checkout's CURRENT main.rs with the pre-fix
-- wording put back. Returns its path, or nil and why.
local function mutant_worktree(tag)
    local W = root .. "/target/plan-scratch/ssh-lane-mutant-" .. tag .. "-" .. tostring(time.now_ms())
    local a = proc.run{ argv = { "git", "-C", root, "worktree", "add", "--detach", "--quiet", W, "HEAD" }, timeout_ms = 300000 }
    if not a.ok then return nil, W, "git worktree add failed: " .. (a.stderr or "") end
    local src = read(root .. "/" .. SRC)
    local s, e = src:find(FIXED, 1, true)
    if not s then return nil, W, "the fixed wording is not in " .. SRC .. " — this fixture has drifted from the code it pins" end
    fs.write(text.trim(W:sub(#root + 2)) .. "/" .. SRC, src:sub(1, s - 1) .. PRE_FIX .. src:sub(e + 1))
    -- A write that did not land must not read as a mutation (the .sh's sed lesson).
    if not read(W .. "/" .. SRC):find(PRE_FIX, 1, true) then return nil, W, "the mutation is not present in the worktree copy" end
    return W
end

local function remove_worktree(W)
    proc.run{ argv = { "git", "-C", root, "worktree", "remove", "--force", "--force", W }, timeout_ms = 120000 }
    proc.run{ argv = { "git", "-C", root, "worktree", "prune" } }
end

-- HOLD MODE (arm 3's child): apply the mutation, say so, and wait to be killed.
if HOLD then
    local W, _, why = mutant_worktree("hold")
    fs.write(HOLD, W and ("applied " .. W .. "\n") or ("failed " .. tostring(why) .. "\n"))
    -- One-second sleeps, not one long one: the KILL lands on this runner, and
    -- a long sleep child would outlive it as an orphan.
    for _ = 1, 600 do proc.run{ argv = { "sleep", "1" } } end
    verdict.emit("skip:ssh-lane-refuses-when-unwired:hold-not-killed", 3)
end

local pass, fail = 0, 0
local function ok(m) out.line("  PASS  " .. m); pass = pass + 1 end
local function bad(m) log.raw("FAIL: " .. m); fail = fail + 1 end

out.line("arm 1 — the behavioural unit arms pass on the fixed source")
local rc, o = unit_arms(nil)
if rc == 0 then ok("write_forge_gitconfig arms green")
else bad("the gitconfig arms do not pass on the current source:\n" .. o) end

out.line("arm 2 — MUTATION: reintroducing the fallback in a scratch worktree must RED the unit arms")
local W, WP, why = mutant_worktree("arm2")
if not W then
    bad("could not apply the mutation (" .. tostring(why) .. ") — arm 2 proves nothing and must not read as a pass")
else
    local mrc = unit_arms(W .. "/Cargo.toml")
    if mrc == 0 then
        bad("MUTATION SURVIVED: the pre-fix fallback wording was reintroduced and the unit arms still passed — the guard has no teeth")
    else ok("the mutated source REDS, so the guard bites") end
end
remove_worktree(W or WP)

out.line("arm 3 — KILLED MID-ARM: the checkout's tracked files stay clean")
local RUNNER = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if not RUNNER or RUNNER == "" then RUNNER = root .. "/target/release/tillandsias-plan" end
local before = proc.run{ argv = { "git", "-C", root, "status", "--porcelain", "--untracked-files=no" } }.stdout or ""
local marker_rel = "target/plan-scratch/ssh-lane-hold-" .. tostring(time.now_ms())
local marker = root .. "/" .. marker_rel
local h = proc.spawn{ argv = { RUNNER, "script", "run", "scripts/lua/test-ssh-lane-refuses-when-unwired.lua" },
    env = { TILLANDSIAS_TEST_SSH_LANE_HOLD = marker }, timeout_ms = 900000 }
local said = ""
for _ = 1, 600 do
    said = read(marker)
    if said ~= "" then break end
    proc.run{ argv = { "sleep", "1" } }
end
h:kill()
local HW = said:match("^applied (%S+)")
local after = proc.run{ argv = { "git", "-C", root, "status", "--porcelain", "--untracked-files=no" } }.stdout or ""
if not HW then
    bad("the held child never applied its mutation (" .. text.trim(said) .. ") — arm 3 proves nothing")
elseif after ~= before then
    bad("a SIGKILLed mutation arm changed the checkout's tracked files:\nbefore:\n" .. before .. "\nafter:\n" .. after)
elseif not read(root .. "/" .. SRC):find(FIXED, 1, true) then
    bad("a SIGKILLed mutation arm left the checkout's " .. SRC .. " without the fixed wording")
else
    ok("a mutation arm SIGKILLed after applying leaves git status as it was and " .. SRC .. " unmutated")
end
if HW then remove_worktree(HW) end
proc.run{ argv = { "find", marker, "-delete" } }

if fail == 0 then
    out.line("ok: ssh-lane-refuses-when-unwired PASS")
    verdict.emit("ok:ssh-lane-refuses-when-unwired:" .. pass, 0)
end
out.line("fail: ssh-lane-refuses-when-unwired (" .. fail .. " arm(s))")
verdict.emit("violation:ssh-lane-refuses-when-unwired:" .. fail, 1)
