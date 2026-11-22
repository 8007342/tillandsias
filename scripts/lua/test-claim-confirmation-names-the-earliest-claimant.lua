-- @trace order:1370-tjme, order:1493-d93i, order:2165-uu9j
-- @env PATH HOME TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-claim-confirmation-names-the-earliest-claimant.lua — the post-claim step
-- must tell the LOSER of a claim race that it lost, and name the winner.
-- Ported from the .sh of the same name (order 2165-uu9j); same eight arms.
--
-- Hermetic: a one-row scratch ledger under target/plan-scratch, claims written
-- as status-channel fragments exactly as `tillandsias-plan set-field` writes
-- them. Arms 1-5 run in a scratch repository with NO origin (judged on the fold
-- alone); arms 6-8 each get a scratch bare origin. Nothing touches this
-- checkout's config or the real origin.
--
-- PRE-FIX RESULT, pinned as arm 1: `tillandsias-plan next <role> | grep -c
-- <order>` reads 0 for BOTH hosts once any claim exists.
--
-- Usage: tillandsias-plan script run scripts/lua/test-claim-confirmation-names-the-earliest-claimant.lua

local ENV = { PATH = env.get("PATH"), HOME = env.get("HOME") }
local function run(argv, cwd)
    return proc.run({ argv = argv, cwd = cwd, env = ENV, timeout_ms = 120000 })
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" then verdict.could_not_run("claim-confirmation-fixture", "not inside a git checkout") end
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or env.get("TILLANDSIAS_PLAN_BIN") or "tillandsias-plan"
local CHECK = ROOT .. "/scripts/lua/check-claim-confirmed.lua"
local REL = "target/plan-scratch/uu9j-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL

local pass, fail = 0, 0
local function arm(name, cond, why)
    if cond then pass = pass + 1; out.line("ok   " .. name)
    else fail = fail + 1; out.line("FAIL " .. name .. " — " .. why) end
end

local ORDER, PID = "9999-zzzz", "fixture-claim-race-row"
local INDEX = "packets:\n  - packet_id: " .. PID .. "\n    order: " .. ORDER .. "\n    status: ready\n"
    .. "    kind: defect\n    priority: p2\n    desired_release: v0.5\n    pickup_role: linux\n"
    .. "    capability_tags: [plan-ledger]\n    estimated_hours: 1\n    title: fixture row\n"
    .. "    verifiable_closure: fixture\n"
local function status_yaml(ts, host, value)
    return "status:\n  - packet_id: " .. PID .. "\n    field: status\n    value: " .. value
        .. "\n    ts: \"" .. ts .. "\"\n    host: " .. host .. "\n"
end
local function git(r, ...)
    local argv = { "git", "-C", r, "-c", "user.name=f", "-c", "user.email=f@f" }
    for _, x in ipairs({ ... }) do argv[#argv + 1] = x end
    return run(argv)
end

-- A no-origin repository whose plan dir is <rel>/plan.
local n = 0
local function fresh()
    n = n + 1
    local rel = REL .. "/race" .. n
    fs.mkdir(rel .. "/plan/index.d")
    fs.write(rel .. "/plan/index.yaml", INDEX)
    run({ "git", "init", "-q", ROOT .. "/" .. rel })
    return rel
end
local function write_status(rel, stamp, ts, host, value)
    fs.write(rel .. "/plan/index.d/" .. stamp .. "-" .. host .. ".yaml", status_yaml(ts, host, value))
end
local function check(rel, host)
    local r = proc.run({ argv = { PLAN, "script", "run", CHECK, "--", ORDER, "--host", host,
        "--plan-dir", ROOT .. "/" .. rel .. "/plan" }, cwd = ROOT, env = ENV, timeout_ms = 300000 })
    return r.code, text.trim(r.stdout or "")
end
local function listed(rel)
    local r = run({ PLAN, "--index", ROOT .. "/" .. rel .. "/plan/index.yaml", "next", "linux", "--release", "v0.5" })
    local c = 0
    for _, l in ipairs(text.lines(r.stdout or "")) do if text.contains(l, ORDER) then c = c + 1 end end
    return c
end

-- arm 1: the pre-fix check cannot tell the two hosts apart
local R = fresh()
arm("premise: the unclaimed row is listed by next", listed(R) >= 1, "next does not list the unclaimed row")
write_status(R, "20260925t192513z", "2026-09-25T19:25:13Z", "hostb", "in_progress")
write_status(R, "20260925t192433z", "2026-09-25T19:24:33Z", "hosta", "in_progress")
arm("pre-fix: next|grep -c prints 0 once claimed — the same answer for both hosts", listed(R) == 0,
    "expected the claimed row hidden from next")

-- arm 2: the loser is refused and told who won
local rc, o = check(R, "hostb")
arm("the later claimant exits 1 and names the earlier claim", rc == 1 and text.contains(o,
    "refused:claim-lost:9999-zzzz:hostb@2026-09-25T19:25:13Z:earlier=hosta@2026-09-25T19:24:33Z"),
    "rc=" .. tostring(rc) .. " out=" .. o)

-- arm 3: the winner is confirmed
rc, o = check(R, "hosta")
arm("the earliest claimant exits 0", rc == 0 and o == "ok:claim-confirmed:9999-zzzz:hosta@2026-09-25T19:24:33Z",
    "rc=" .. tostring(rc) .. " out=" .. o)

-- arm 4: a release resets the race; the next claim after it wins
R = fresh()
write_status(R, "20260925t100000z", "2026-09-25T10:00:00Z", "hosta", "in_progress")
write_status(R, "20260925t110000z", "2026-09-25T11:00:00Z", "hosta", "ready")
write_status(R, "20260925t120000z", "2026-09-25T12:00:00Z", "hostb", "in_progress")
rc, o = check(R, "hostb")
arm("a claim after a release to ready is confirmed", rc == 0, "rc=" .. tostring(rc) .. " out=" .. o)
rc, o = check(R, "hosta")
arm("the released host holds no live claim", rc == 1 and text.contains(o, "refused:no-live-claim:9999-zzzz:hosta:held-by=hostb"),
    "rc=" .. tostring(rc) .. " out=" .. o)

-- arm 5: a host that never claimed is refused, not confirmed
R = fresh()
rc, o = check(R, "hosta")
arm("no claim is not a confirmation", rc == 1 and o == "refused:no-live-claim:9999-zzzz:hosta",
    "rc=" .. tostring(rc) .. " out=" .. o)

-- arms 6-8 (1493-d93i): THE CLAIM MUST BE ON ORIGIN
local function repo_with_claim(name, origin, refuse)
    local rel = REL .. "/" .. name
    local r = ROOT .. "/" .. rel
    run({ "git", "init", "-q", "-b", "linux-next", r })
    fs.mkdir(rel .. "/plan/index.d")
    fs.write(rel .. "/plan/index.yaml", INDEX)
    git(r, "add", "-A"); git(r, "commit", "-qm", "base")
    git(r, "remote", "add", "origin", origin)
    git(r, "push", "-q", "origin", "linux-next")
    git(r, "branch", "-q", "--set-upstream-to=origin/linux-next", "linux-next")
    if refuse then  -- origin refuses every push from here on
        local hrel = origin:sub(#ROOT + 2) .. "/hooks/pre-receive"
        fs.write(hrel, "#!/bin/sh\necho refused >&2\nexit 1\n")
        run({ "chmod", "+x", origin .. "/hooks/pre-receive" })
    end
    fs.write(rel .. "/plan/index.d/20260929t120000z-hosta.yaml", status_yaml("2026-09-29T12:00:00Z", "hosta", "in_progress"))
    git(r, "add", "-A"); git(r, "commit", "-qm", "claim")
    git(r, "push", "-q", "origin", "linux-next")
    return rel
end

-- arm 6: origin REFUSES the claim push, so the claim lives only in the checkout
run({ "git", "init", "-q", "--bare", "-b", "linux-next", W .. "/refusing.git" })
rc, o = check(repo_with_claim("refusing-clone", W .. "/refusing.git", true), "hosta")
arm("a claim whose push was REFUSED is not confirmed (claim-not-on-origin)",
    rc == 1 and text.contains(o, "refused:claim-not-on-origin:9999-zzzz:hosta"), "rc=" .. tostring(rc) .. " out=" .. o)

-- arm 7: NEGATIVE CONTROL, origin ACCEPTS the claim, so it is confirmed
run({ "git", "init", "-q", "--bare", "-b", "linux-next", W .. "/accepting.git" })
rc, o = check(repo_with_claim("accepting-clone", W .. "/accepting.git", false), "hosta")
arm("a claim that reached origin is still confirmed", rc == 0 and text.contains(o, "ok:claim-confirmed:9999-zzzz:hosta"),
    "rc=" .. tostring(rc) .. " out=" .. o)

-- arm 8: origin cannot be asked: unknown, never a pass
rc, o = check(repo_with_claim("unreachable-clone", W .. "/does-not-exist.git", false), "hosta")
arm("an unreachable origin is unknown, not confirmed", rc == 3 and text.contains(o, "could-not-run:claim-origin-unreachable:9999-zzzz:hosta"),
    "rc=" .. tostring(rc) .. " out=" .. o)

run({ "rm", "-rf", W })
if fail > 0 then verdict.emit("violation:claim-confirmation-fixture:" .. fail .. "-failed", 1) end
verdict.ok("claim-confirmation-fixture", pass .. "/" .. (pass + fail) .. " (1370-tjme, 1493-d93i)")
