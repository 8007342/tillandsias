-- @trace order:940-f77j, order:2234-gmmc
--
-- ORDER 940-f77j — a gate stamp must be EARNED, not merely written.
-- Ported from test-gate-stamp-must-be-earned.sh (2234-gmmc).
--
-- build.sh reaches _write_gate_stamp only after every check passes, so its own
-- stamps were always honest. The hole was that `gate-stamp.sh write` is a public
-- entry point: the invariant lived in build.sh's control flow, not in the thing
-- that writes the artifact. On 2026-08-29 an agent ran
--
--     ./build.sh --check; scripts/gate-stamp.sh write; git push
--
-- with semicolons rather than `&&`. The gate exited 1 on a real violation, the
-- next command stamped anyway, and a red tree landed on trunk under a stamp
-- asserting it was green. The vulnerability was never the punctuation — a
-- guarantee whose enforcement lives in every caller's shell is not enforced, it
-- is documented.
--
-- Arm 3 replays that sequence VERBATIM, semicolons included (a helper file
-- holds the literal shell), because a control written with `&&` would pass
-- against exactly the shell discipline the fix exists to stop depending on.
--
--   1 green gate -> token issued -> stamp accepted, and the token consumed
--   2 red gate -> no token -> stamp refused, no stamp written
--   3 THE INCIDENT verbatim: a red gate, then an unconditional write -> refused
--   4 STALE TOKEN: green gate, then the tree changes, then stamp -> refused, token gone
--
-- Verdict: ok:gate-stamp-must-be-earned:4 arms | violation:gate-stamp-must-be-earned:arm-<n>

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local STAMP = root .. "/scripts/gate-stamp.sh"
local rel = "target/plan-scratch/gate-stamp-earned-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
local REPO = W .. "/repo"
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end
local function fail(arm, m)
    out.line("FAIL: arm " .. arm .. ": " .. m)
    cleanup()
    verdict.emit("violation:gate-stamp-must-be-earned:arm-" .. arm, 1)
end

-- A throwaway repo: the token and stamp both live in ITS git dir, so nothing
-- here can touch the real checkout's gate state.
local GENV = { GIT_CONFIG_GLOBAL = "/dev/null" }
local function in_repo(argv)
    local r = proc.run{ argv = argv, cwd = REPO, env = GENV, timeout_ms = 120000 }
    return r.code, (r.stdout or "") .. (r.stderr or ""), r.stdout or ""
end
proc.run{ argv = { "mkdir", "-p", REPO } }
in_repo({ "git", "init", "-q", "." })
in_repo({ "git", "config", "user.email", "t@t" })
in_repo({ "git", "config", "user.name", "t" })
fs.write(rel .. "/repo/file.txt", "hello\n")
in_repo({ "git", "add", "-A" })
in_repo({ "git", "commit", "-qm", "init" })
local _, _, gd = in_repo({ "git", "rev-parse", "--absolute-git-dir" })
local GITDIR = text.trim(gd)
if GITDIR:sub(1, #W) ~= W then
    cleanup()
    verdict.could_not_run("gate-stamp-must-be-earned:scratch-git-dir-outside-the-scratch:" .. GITDIR)
end
local GD_REL = rel .. GITDIR:sub(#W + 1)
local TOKEN, STAMP_FILE = GD_REL .. "/tillandsias-gate-pass-token", GD_REL .. "/tillandsias-gate-stamp"
local function rm(p) if fs.exists(p) then proc.run{ argv = { "find", root .. "/" .. p, "-delete" } } end end

local function issue_token()  -- what a GREEN build.sh does
    local _, _, digest = in_repo({ "bash", STAMP, "compute" })
    fs.write(TOKEN, "version 1\ndigest " .. text.trim(digest) .. "\ndispatch check\nissued now\n")
end
local function write_stamp() return in_repo({ "bash", STAMP, "write", "--scope", "full", "--dispatch", "check" }) end

-- arm 1: green gate -> token issued -> stamp accepted
issue_token()
local rc, said = write_stamp()
if rc ~= 0 then fail(1, "a stamp backed by a matching pass token was refused: " .. said) end
if not fs.exists(STAMP_FILE) then fail(1, "accepted but wrote no stamp") end
if fs.exists(TOKEN) then fail(1, "the token was not consumed — it could authorise a second stamp") end

-- arm 2: red gate -> no token -> stamp refused
rm(STAMP_FILE); rm(TOKEN)
rc, said = write_stamp()
if rc == 0 then fail(2, "a stamp was written with no pass token at all: " .. said) end
if not said:find("refused:no-gate-pass-token", 1, true) then fail(2, "wrong refusal: " .. said) end
if fs.exists(STAMP_FILE) then fail(2, "refused but wrote a stamp anyway") end

-- arm 3: THE INCIDENT, verbatim — red gate, then an unconditional write.
-- Semicolons, exactly as typed on 2026-08-29. The false gate here exits 1.
rm(STAMP_FILE); rm(TOKEN)
fs.write(rel .. "/incident.sh", "{ false; } ; bash \"$1\" write --scope full --dispatch check\n")
rc, said = in_repo({ "bash", W .. "/incident.sh", STAMP })
if rc == 0 then fail(3, "THE INCIDENT REPRODUCES — a red gate's stamp was accepted") end
if fs.exists(STAMP_FILE) then fail(3, "THE INCIDENT REPRODUCES — a stamp exists after a red gate") end
if not said:find("refused:", 1, true) then fail(3, "refused without saying so: " .. said) end

-- arm 4: STALE TOKEN — green gate, then the tree changes, then stamp.
-- A token keyed to a different tree is "a gate passed" wearing "this tree
-- passed" as a costume. Refusing only the missing-token case would leave the
-- door open at the hinge.
rm(STAMP_FILE); rm(TOKEN)
issue_token()
fs.write(rel .. "/repo/file.txt", fs.read(rel .. "/repo/file.txt") .. "edited after the gate ran\n")
rc, said = write_stamp()
if rc == 0 then fail(4, "a token issued for a DIFFERENT tree was accepted: " .. said) end
if not said:find("refused:gate-pass-token-is-for-another-tree", 1, true) then fail(4, "wrong refusal: " .. said) end
if fs.exists(STAMP_FILE) then fail(4, "refused but wrote a stamp anyway") end
if fs.exists(TOKEN) then fail(4, "a token that vouched for another tree was left live") end

cleanup()
out.line("ok: a gate stamp cannot be written without a pass token the gate itself issued (940-f77j)")
verdict.ok("gate-stamp-must-be-earned:4 arms")
