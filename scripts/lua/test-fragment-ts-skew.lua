-- @trace order:1313-w78k, order:1581-d9ig
--
-- test-fragment-ts-skew.lua — both directions of check-fragment-ts-skew.sh's
-- asymmetric rule, and the asymmetry IS the contract: a future ts is refused
-- with no declaration that admits it, a past ts is accepted and printed. A
-- fixture that only proved the refusal would pass a checker that refused
-- everything, which would break every relay fold in the fleet — lenovinha's
-- fragments are written hours before they are folded.
--
-- The Lua port of scripts/test-fragment-ts-skew.sh (1581-d9ig). The .sh's
-- teardown ran `git -C "$ROOT" worktree prune` on the operator's checkout,
-- which inside the WSL guest deletes every Windows worktree the guest cannot
-- see; this port removes only its OWN worktree. Its timestamps come from
-- time.now_ms, so the GNU `date -d` / BSD `date -v` probing the .sh needed
-- (and got wrong on macOS until 2026-09-20) is gone.
--
-- ORDER 1320-44rs: the probe is planted in a scratch WORKTREE of HEAD (the
-- same refs and the same diff base), never in the live plan/index.d, where a
-- run killed between plant and cleanup left a fragment the fold reads as real.
-- Only the checker and plan/index.d are checked out (the checker diffs AM
-- against the base, so absent paths are deletions it ignores), and the checker
-- is the WORKING-TREE copy, so an uncommitted edit to it is what gets tested.
--
-- Usage: tillandsias-plan script run scripts/lua/test-fragment-ts-skew.lua

local CHECK = "scripts/check-fragment-ts-skew.sh"
local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 120000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" or not fs.exists(CHECK) then
    verdict.could_not_run("fragment-ts-skew-fixture", "no checkout with " .. CHECK .. " here")
end

-- Seconds since the epoch, shifted, as 2026-09-20T12:00:00Z. Civil-from-days
-- (Howard Hinnant's algorithm): no host `date`, so no GNU/BSD divergence.
local function iso_at(offset_s)
    local t = math.floor(time.now_ms() / 1000) + offset_s
    local days, secs = math.floor(t / 86400), t % 86400
    local z = days + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    local y = yoe + era * 400 + (m <= 2 and 1 or 0)
    return ("%04d-%02d-%02dT%02d:%02d:%02dZ"):format(y, m, d, math.floor(secs / 3600), math.floor(secs % 3600 / 60), secs % 60)
end

local WT_REL = "target/plan-scratch/fragment-ts-skew-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local WT = ROOT .. "/" .. WT_REL
-- Removes THIS fixture's worktree and nothing else (1581-d9ig: never a prune).
local function teardown() run({ "git", "-C", ROOT, "worktree", "remove", "--force", WT }); run({ "rm", "-rf", WT }) end

local add = run({ "git", "-C", ROOT, "worktree", "add", "--no-checkout", "--detach", "-q", WT, "HEAD" })
local co = add.code == 0 and run({ "git", "-C", WT, "checkout", "-q", "HEAD", "--", "plan/index.d", CHECK }) or add
if not (add.code == 0 and co.code == 0) then
    teardown()
    verdict.could_not_run("fragment-ts-skew-fixture", "could not build the scratch worktree: " .. (add.stderr or "") .. (co.stderr or ""))
end
fs.write(WT_REL .. "/" .. CHECK, fs.read(CHECK))

local PROBE = "plan/index.d/zz-1313-probe.yaml"
local function plant(ts)
    fs.write(WT_REL .. "/" .. PROBE, ("events:\n  - packet_id: probe\n    event:\n      type: note\n      ts: \"%s\"\n      agent_id: probe\n      host: probe\n      summary: probe\n"):format(ts))
end
local function checker()
    local r = run({ "bash", CHECK }, { cwd = WT })
    return (r.status == "exited" and r.code or -1), (r.stdout or "") .. (r.stderr or "")
end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end

local passed, failed = {}, {}
local function check(name, cond)
    if cond then passed[#passed + 1] = name; out.line("  [OK]   " .. name)
    else failed[#failed + 1] = name; out.line("  [FAIL] " .. name) end
end

-- ── ARM 1: two hours ahead is REFUSED, and the file is named ────────────────
plant(iso_at(7200))
local rc, o = checker()
check("a ts two hours AHEAD is refused (rc=" .. rc .. ")", rc ~= 0)
check("the refusal names the file", has(o, PROBE))
check("the refusal says a future ts is not a backfill", has(o, "not a backfill"))
check("the refusal carries a remedy the operator can type", has(o, "date -u"))

-- ── ARM 2: two hours behind is ACCEPTED and PRINTED ─────────────────────────
-- The load-bearing half. A delayed push is real and common. SCOPED TO THE
-- PROBE: the checker reports on EVERY newly added fragment, so an unscoped
-- match passes as soon as any unrelated fragment is more than the limit old.
plant(iso_at(-7200))
rc, o = checker()
check("a ts two hours BEHIND is accepted (rc=" .. rc .. ")", rc == 0)
check("the past skew is PRINTED, not swallowed", has(o, "note:fragment-ts-past:" .. PROBE .. ":"))

-- ── ARM 3: CONTROL — a clock-read ts is accepted with no note ───────────────
-- SCOPED TO THE PROBE, and this is the arm that caught it (macneo 2026-09-20:
-- merged fragments 930s old were noted and an unscoped control failed).
plant(iso_at(0))
rc, o = checker()
check("CONTROL: a ts read from the clock is accepted", rc == 0)
check("CONTROL: a current ts produces no note", not has(o, "note:fragment-ts-past:" .. PROBE .. ":"))

-- ── ARM 4: NEGATIVE CONTROL — the check is DIFF-SCOPED ──────────────────────
-- Fragments already on the base ref are not re-judged: one host's mistake must
-- not turn every other host's gate red (698-7n6q's construction).
run({ "rm", "-f", WT .. "/" .. PROBE })
rc = checker()
check("NEGATIVE CONTROL: with nothing added, the check is silent and passes", rc == 0)

teardown()
out.line(("fragment-ts-skew %d/%d"):format(#passed, #passed + #failed))
if #failed > 0 then
    verdict.emit("violation:fragment-ts-skew-fixture:" .. #failed .. ":of:" .. (#passed + #failed), 1,
        "failed arms: " .. table.concat(failed, "; "))
end
verdict.emit(("ok:fragment-ts-skew-fixture:%d/%d"):format(#passed, #passed), 0)
