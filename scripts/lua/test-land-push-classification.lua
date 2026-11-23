-- @trace order:1366-d5v2, order:1524-7gn7, order:2209-jw2t
-- @env TILLANDSIAS_LAND_UNDER_TEST
-- @env PATH
--
-- test-land-push-classification.lua — PORTED from
-- test-land-push-classification.sh (2209-jw2t), same arms, same lines. Pins
-- WHAT the land tool pushes and HOW it names a push that did not land.
--
-- Measured on yoga 2026-09-23: run from a work branch, the tool merged trunk
-- into HEAD and gated HEAD, then pushed the LOCAL linux-next, a stale
-- ancestor of trunk; refused non-fast-forward, it printed "origin moved —
-- retrying" four times while origin never moved.
--
--   ARM 1  HEAD is a work branch, local linux-next is a stale ancestor of
--          origin: the tool lands HEAD.
--   ARM 2  a race-shaped failure while origin does NOT move: no "origin
--          moved"; refused by name, the push's own output printed.
--   ARM 3  CONTROL: origin genuinely moves during the first push; still a
--          race, retried, lands.
--   ARM 5  origin moves during the GATE and the gate's fetch updates the
--          tracking ref: still a lost race, retried, lands.
--   ARM 4  from a linked worktree whose credential helper is a RELATIVE
--          `store --file=.git/...`, an auth failure names that cause.
--   ARM 6  origin moves and the PRE-PUSH HOOK refuses in its own words: a
--          lost race whatever the text; re-integrates and lands (1524-7gn7).
--   ARM 7  CONTROL for 6: the same refusal with origin UNMOVED stops after
--          one push (rc 6).
--
-- Hermetic: scratch bare origin and checkout under target/plan-scratch (never
-- the real checkout's HEAD — 2196-rdec, clean by construction), a copy of the
-- tool, a green stub gate, and a `git` wrapper on PATH that intercepts
-- `push` only. TILLANDSIAS_LAND_UNDER_TEST overrides the tool (mutation control).
--
-- Verdict: ok:land-push-classification:<p>/<p> | violation:land-push-classification:<f>

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local LANDSH = env.get("TILLANDSIAS_LAND_UNDER_TEST") or (root .. "/scripts/land-on-platform-branch.sh")
local PATH = env.get("PATH") or "/usr/bin:/bin"
local REAL_GIT
for dir in PATH:gmatch("[^:]+") do
    if not REAL_GIT and proc.run{ argv = { "test", "-x", dir .. "/git" } }.ok then REAL_GIT = dir .. "/git" end
end
if not REAL_GIT then verdict.could_not_run("land-push-classification:no-git") end

local passes, fails = 0, 0
local function ok(m) passes = passes + 1; out.line("ok: " .. m) end
local function bad(m) fails = fails + 1; out.line("FAIL: " .. m) end
local function G(args, cwd)
    local a = { REAL_GIT, "-c", "user.email=t@t", "-c", "user.name=t" }
    for _, x in ipairs(args) do a[#a + 1] = x end
    return proc.run{ argv = a, cwd = cwd, timeout_ms = 120000 }
end
local function trim(s) return text.trim(s or "") end
local function c9(s) return (s or ""):sub(1, 9) end
local function tail2(s)
    local ls = text.lines((s or ""):gsub("\n+$", ""))
    local t = {}
    for i = math.max(1, #ls - 1), #ls do t[#t + 1] = ls[i] .. " " end
    return table.concat(t)
end
local function has_prefix(s, p) for _, l in ipairs(text.lines(s or "")) do if l:sub(1, #p) == p then return true end end return false end
local function has(s, p) return (s or ""):find(p, 1, true) ~= nil end

local seq = 0
local function cleanup(d) proc.run{ argv = { "find", d, "-delete" }, timeout_ms = 60000 } end

local WRAP = [[#!/usr/bin/env bash
if [ "${1:-}" = "push" ]; then
    echo "$*" >> "@D@/pushes"
    mode=$(cat "@D@/mode")
    case "$mode" in
        fail-unmoved)
            echo " ! [rejected]        linux-next -> linux-next (non-fast-forward)" >&2
            echo "error: failed to push some refs to '@D@/origin.git'" >&2
            exit 1 ;;
        move-then-fail)
            echo passthrough > "@D@/mode"
            "@GIT@" clone -q -b linux-next "@D@/origin.git" "@D@/other" 2>/dev/null
            "@GIT@" -C "@D@/other" -c user.email=o@o -c user.name=o commit -q --allow-empty -m "sibling landed"
            "@GIT@" -C "@D@/other" push -q origin linux-next
            echo " ! [rejected]        linux-next -> linux-next (fetch first)" >&2
            exit 1 ;;
        hook-after-move)
            echo passthrough > "@D@/mode"
            "@GIT@" clone -q -b linux-next "@D@/origin.git" "@D@/other" 2>/dev/null
            "@GIT@" -C "@D@/other" -c user.email=o@o -c user.name=o commit -q --allow-empty -m "plan-only push from another host"
            "@GIT@" -C "@D@/other" push -q origin linux-next
            echo "✗ pre-push refused: the gate stamp is scoped to 'build-scripts,specs' but refs/heads/linux-next has no usable local base to diff against" >&2
            echo "error: failed to push some refs to '@D@/origin.git'" >&2
            exit 1 ;;
        hook-unmoved)
            echo "✗ pre-push refused: a decider refused this tree" >&2
            echo "error: failed to push some refs to '@D@/origin.git'" >&2
            exit 1 ;;
        auth)
            echo "fatal: could not read Username for 'https://github.com': terminal prompts disabled" >&2
            exit 128 ;;
    esac
fi
exec "@GIT@" "$@"
]]
local function subst(s, d) return (s:gsub("@D@", function() return d end):gsub("@GIT@", function() return REAL_GIT end)) end

-- scratch <push-mode>: passthrough | fail-unmoved | move-then-fail | hook-after-move | hook-unmoved | auth
local function scratch(mode)
    seq = seq + 1
    local rel = "target/plan-scratch/land-push-class-" .. tostring(time.now_ms()) .. "-" .. seq
    local d = root .. "/" .. rel
    proc.run{ argv = { "mkdir", "-p", d .. "/w/scripts", d .. "/bin" } }
    G({ "init", "-q", "--bare", d .. "/origin.git" })
    G({ "init", "-q", "-b", "linux-next", d .. "/w" })
    -- The tool rebases and merges with the REAL git, which needs an identity.
    G({ "-C", d .. "/w", "config", "user.email", "t@t" })
    G({ "-C", d .. "/w", "config", "user.name", "t" })
    G({ "-C", d .. "/w", "remote", "add", "origin", d .. "/origin.git" })
    proc.run{ argv = { "cp", LANDSH, d .. "/w/scripts/land-on-platform-branch.sh" } }
    fs.write(rel .. "/w/build.sh", "#!/usr/bin/env bash\nexit 0\n")
    proc.run{ argv = { "chmod", "+x", d .. "/w/build.sh" } }
    G({ "-C", d .. "/w", "add", "-A" })
    G({ "-C", d .. "/w", "commit", "-q", "-m", "base" })
    G({ "-C", d .. "/w", "push", "-q", "origin", "linux-next" })
    fs.write(rel .. "/mode", mode .. "\n")
    fs.write(rel .. "/pushes", "")
    fs.write(rel .. "/bin/git", subst(WRAP, d))
    proc.run{ argv = { "chmod", "+x", d .. "/bin/git" } }
    return d, rel
end
local function run_land(d, wd)
    local r = proc.run{ argv = { "bash", "scripts/land-on-platform-branch.sh", "linux-next", "2" }, cwd = wd, stdin = "",
        env = { PATH = d .. "/bin:" .. PATH, GIT_TERMINAL_PROMPT = "0", TILLANDSIAS_LAND_AUTH_RETRY_DELAY = "0" },
        timeout_ms = 600000 }
    return r.stdout or "", r.stderr or "", tostring(r.code)
end
local function origin_head(d) return trim(proc.run{ argv = { REAL_GIT, "--git-dir=" .. d .. "/origin.git", "rev-parse", "refs/heads/linux-next" } }.stdout) end

-- ARM 1: land from a work branch while local linux-next is a stale ancestor.
local d, rel = scratch("passthrough")
local w = d .. "/w"
G({ "-C", w, "switch", "-q", "-c", "work/0000-test" })
G({ "-C", w, "commit", "-q", "--allow-empty", "-m", "the gated work" })
G({ "-C", w, "branch", "-f", "linux-next", trim(G({ "-C", w, "rev-list", "--max-parents=0", "HEAD" }).stdout) })
G({ "clone", "-q", "-b", "linux-next", d .. "/origin.git", d .. "/sib" })
G({ "-C", d .. "/sib", "commit", "-q", "--allow-empty", "-m", "trunk moved before the land" })
G({ "-C", d .. "/sib", "push", "-q", "origin", "linux-next" })
local o, e, rc = run_land(d, w)
local head_now = trim(G({ "-C", w, "rev-parse", "HEAD" }).stdout)
if origin_head(d) == head_now then ok("ARM 1: from a work branch the tool lands HEAD, not the local linux-next")
else bad("ARM 1: origin=" .. c9(origin_head(d)) .. " HEAD=" .. c9(head_now) .. " rc=" .. rc .. " " .. tail2(e)) end
cleanup(d)

-- ARM 2: race-shaped failure, origin unmoved -> refuse by name, no "origin moved".
d = scratch("fail-unmoved"); w = d .. "/w"
G({ "-C", w, "commit", "-q", "--allow-empty", "-m", "unpushed" })
local before = origin_head(d)
o, e, rc = run_land(d, w)
if origin_head(d) ~= before then bad("ARM 2 PREMISE: origin moved in the unmoved arm") end
if has(o, "origin moved") or has(e, "origin moved") then
    bad("ARM 2: said 'origin moved' while origin sat at " .. c9(before))
else ok("ARM 2: no 'origin moved' when origin did not move") end
if has_prefix(e, "refused:land:push-failed-origin-unmoved:") then ok("ARM 2: refused by name (rc=" .. rc .. ")")
else bad("ARM 2: no refused:land:push-failed-origin-unmoved verdict (rc=" .. rc .. ")") end
if has(e, "non-fast-forward") then ok("ARM 2: the push's own output is printed")
else bad("ARM 2: the push log was not shown") end
cleanup(d)

-- ARM 3 (CONTROL): origin really moves during the push -> still a race, lands.
d = scratch("move-then-fail"); w = d .. "/w"
G({ "-C", w, "commit", "-q", "--allow-empty", "-m", "unpushed" })
o, e, rc = run_land(d, w)
if has(o, "origin moved") then ok("ARM 3 CONTROL: a real move is still reported as origin moved")
else bad("ARM 3 CONTROL: no 'origin moved' line for a real move") end
if has_prefix(o, "ok:land:") then ok("ARM 3 CONTROL: the retry lands")
else bad("ARM 3 CONTROL: did not land (rc=" .. rc .. ") " .. tail2(e)) end
cleanup(d)

-- ARM 5: origin moves DURING THE GATE, and the gate's own fetch updates the
-- tracking ref before the push.
d, rel = scratch("passthrough"); w = d .. "/w"
G({ "clone", "-q", "-b", "linux-next", d .. "/origin.git", d .. "/sib" })
fs.write(rel .. "/w/build.sh", subst([[#!/usr/bin/env bash
if [ ! -e "@D@/moved-once" ]; then
    : > "@D@/moved-once"
    "@GIT@" -c user.email=t@t -c user.name=t -C "@D@/sib" commit -q --allow-empty -m "plan-lane push during the gate"
    "@GIT@" -C "@D@/sib" push -q origin linux-next
    "@GIT@" fetch -q origin
fi
exit 0
]], d))
proc.run{ argv = { "chmod", "+x", w .. "/build.sh" } }
G({ "-C", w, "add", "-A" }); G({ "-C", w, "commit", "-q", "-m", "a gate that fetches while origin moves" })
o, e, rc = run_land(d, w)
head_now = trim(G({ "-C", w, "rev-parse", "HEAD" }).stdout)
if has_prefix(e, "refused:land:push-failed-origin-unmoved") then
    bad("ARM 5: a real mid-gate move was refused as origin-unmoved (rc=" .. rc .. ")")
elseif origin_head(d) == head_now and has_prefix(o, "ok:land:") then
    ok("ARM 5: a move seen by the gate's own fetch is still a race; the retry lands")
else bad("ARM 5: did not land (rc=" .. rc .. ") " .. tail2(e)) end
cleanup(d)

-- ARM 4: linked worktree + relative store helper -> the cause is named.
d = scratch("auth"); w = d .. "/w"
G({ "-C", w, "config", "credential.helper", "store --file=.git/.gh-credentials" })
G({ "-C", w, "worktree", "add", "-q", "-b", "wt-branch", d .. "/wt" })
proc.run{ argv = { "cp", LANDSH, d .. "/wt/scripts/land-on-platform-branch.sh" } }
G({ "-C", d .. "/wt", "commit", "-q", "--allow-empty", "-m", "unpushed" })
o, e, rc = run_land(d, d .. "/wt")
if rc == "5" then ok("ARM 4: auth failure still refuses with exit 5") else bad("ARM 4: rc=" .. rc .. ", wanted 5") end
if has(e, "cause:land:relative-credential-store-in-linked-worktree:.git/.gh-credentials") then
    ok("ARM 4: the relative-helper-in-a-worktree cause is named")
else
    local m = {}
    for _, l in ipairs(text.lines(e)) do if #m < 2 and (l:find("refused", 1, true) or l:find("cause", 1, true)) then m[#m + 1] = l .. " " end end
    bad("ARM 4: cause not named: " .. table.concat(m))
end
cleanup(d)

-- ARM 6 (1524-7gn7): origin moves and the PRE-PUSH HOOK refuses in its own words.
d = scratch("hook-after-move"); w = d .. "/w"
G({ "-C", w, "commit", "-q", "--allow-empty", "-m", "work that loses a race to a plan-only push" })
o, e, rc = run_land(d, w)
head_now = trim(G({ "-C", w, "rev-parse", "HEAD" }).stdout)
if has(e, "not a lost race") then
    bad("ARM 6: a hook refusal after origin moved was called 'not a lost race' (rc=" .. rc .. ")")
elseif origin_head(d) == head_now and has_prefix(o, "ok:land:") then
    ok("ARM 6: a hook refusal while origin moved is a lost race; the tool re-integrates and lands")
else bad("ARM 6: did not land (rc=" .. rc .. ") " .. tail2(e)) end
cleanup(d)

-- ARM 7 (CONTROL for ARM 6): a hook refusal with origin UNMOVED still stops.
d, rel = scratch("hook-unmoved"); w = d .. "/w"
G({ "-C", w, "commit", "-q", "--allow-empty", "-m", "work a decider refuses" })
o, e, rc = run_land(d, w)
local np = #text.lines((fs.read(rel .. "/pushes") or ""):gsub("\n+$", ""))
if (fs.read(rel .. "/pushes") or "") == "" then np = 0 end
if rc == "6" and np == 1 then
    ok("ARM 7 CONTROL: a hook refusal with origin unmoved stops after one push (rc 6)")
else bad("ARM 7 CONTROL: rc=" .. rc .. " pushes=" .. np) end
cleanup(d)

out.line("land-push-classification fixture: " .. passes .. " passed, " .. fails .. " failed")
if fails == 0 then verdict.emit("ok:land-push-classification:" .. passes .. "/" .. passes, 0) end
verdict.emit("violation:land-push-classification:" .. fails, 1)
