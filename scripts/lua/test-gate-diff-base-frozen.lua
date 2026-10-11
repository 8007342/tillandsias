-- @trace order:1592-idmu, spec:ci-release
--
-- test-gate-diff-base-frozen.lua — the diff-scoped guards read a base frozen at
-- gate start, so a fetch during the gate cannot flip their verdict.
--
-- THE MEASURED CASE (tlatoanis-macbook-air 2026-10-11). A fetch in the main
-- checkout mid-gate moved origin/linux-next, the ref every worktree shares,
-- past a fix trunk had made to a file the gated tree still carried in its old
-- form. check-sigpipe-verdict-pipelines-added diffed against the moved ref,
-- read the old line as this change ADDING a SIGPIPE-decided pipeline, and
-- refused a gate whose tests were green.
--
--   1 MOVING REF, PRE-FIX: in a scratch repo, the base is frozen at A, then the
--     live ref moves to B, which fixes victim.sh. The guard WITHOUT the frozen
--     fallback (this tree's guard with that one fallback stripped) refuses
--     falsely.
--   2 MOVING REF, FIXED: the same run, with the same environment, through this
--     tree's guard keeps its ok.
--   3 TEETH: with the base frozen, a pipeline the change really adds is still
--     refused.
--   4 FREEZE: build.sh freezes the base before any guard (--preflight after
--     its own fetch); the pre-push hook freezes before anything in it can
--     fetch, and refuses a foreign inherited base.
--   4b INHERITED: build.sh's own function, run in the scratch repo, keeps an
--     inherited base that is an ancestor of HEAD, refuses one frozen for
--     another branch with refused:gate-diff-base:inherited-not-ancestor:<sha>,
--     freezes its own when none is inherited, and sets aside a base frozen
--     for ANOTHER checkout (a fixture's scratch repo); the note says which.
--   5 POPULATION: every diff base under scripts/ (not test-*) that defaults to
--     the live origin/linux-next falls back through TILLANDSIAS_GATE_DIFF_BASE
--     first. Each site is listed and the count printed.
--
-- Terminal line: ok:gate-diff-base-frozen-fixture:<n> or
-- refused:gate-diff-base-frozen-fixture:<failed>.
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-diff-base-frozen.lua

local GUARD = "scripts/check-sigpipe-verdict-pipelines-added.sh"
local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local REL = "target/plan-scratch/gate-diff-base-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local S = ROOT .. "/" .. REL
fs.mkdir(REL .. "/repo/scripts")
fs.mkdir(REL .. "/tools")
local passed, failed = 0, 0
local function ok(m) out.line("ok: " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL: " .. m); failed = failed + 1 end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end

local REPO = S .. "/repo"
local function git(args)
    local argv = { "git", "-C", REPO, "-c", "user.name=fixture", "-c", "user.email=fixture@local", "-c", "commit.gpgsign=false" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 30000 })
    return r.code == 0, text.trim(r.stdout or "")
end
local PIPE = "#!/usr/bin/env bash\nset -uo pipefail\nif cat /etc/hosts | grep -q root; then :; fi\n"
local FIXED = "#!/usr/bin/env bash\nset -uo pipefail\nh=\"$(cat /etc/hosts)\"\nif grep -q root <<<\"$h\"; then :; fi\n"

-- A: trunk at the gate's base, carrying the old pipeline in victim.sh.
git({ "init", "-q", "-b", "linux-next" })
fs.write(REL .. "/repo/scripts/victim.sh", PIPE)
git({ "add", "-A" }); git({ "commit", "-qm", "A: base" })
local _, A = git({ "rev-parse", "HEAD" })
-- The change: an unrelated commit on a work branch from A.
git({ "checkout", "-qb", "work" })
fs.write(REL .. "/repo/scripts/other.sh", "#!/usr/bin/env bash\nset -uo pipefail\necho other\n")
git({ "add", "-A" }); git({ "commit", "-qm", "work: unrelated" })
-- B: trunk fixes victim.sh after the gate's base.
git({ "checkout", "-q", "linux-next" })
fs.write(REL .. "/repo/scripts/victim.sh", FIXED)
git({ "add", "-A" }); git({ "commit", "-qm", "B: trunk fixes victim.sh" })
local _, B = git({ "rev-parse", "HEAD" })
git({ "checkout", "-q", "work" })

-- Gate start: the live ref is A and the base is frozen. Then a fetch moves it to B.
git({ "update-ref", "refs/remotes/origin/linux-next", A })
local _, FROZEN = git({ "merge-base", "HEAD", "origin/linux-next" })
git({ "update-ref", "refs/remotes/origin/linux-next", B })

-- The pre-fix guard: this tree's guard with the frozen fallback stripped.
local cur = fs.read(GUARD)
local pre = cur:gsub("%${TILLANDSIAS_GATE_DIFF_BASE:%-origin/linux%-next}", "origin/linux-next")
fs.write(REL .. "/tools/pre-fix.sh", pre)
local function run_guard(path)
    local r = proc.run({ argv = { "bash", path }, env = { TILLANDSIAS_SIGPIPE_ROOT = REPO, TILLANDSIAS_GATE_DIFF_BASE = FROZEN, TILLANDSIAS_SIGPIPE_BASE = "" }, timeout_ms = 60000 })
    return (r.status == "exited" and r.code or -1), text.trim((r.stdout or "") .. "\n" .. (r.stderr or ""))
end

if pre == cur or FROZEN ~= A then
    bad("premise: the fallback was not found to strip, or the frozen base is not A (frozen=" .. FROZEN .. ")")
else
    local rc, o = run_guard(S .. "/tools/pre-fix.sh")
    if rc ~= 0 and has(o, "victim.sh") then ok("pre-fix guard, live ref moved to B: refuses falsely on victim.sh (rc=" .. rc .. ")")
    else bad("pre-fix guard did not show the false refusal (rc=" .. rc .. "): " .. o:sub(1, 200)) end
    rc, o = run_guard(ROOT .. "/" .. GUARD)
    if rc == 0 then ok("fixed guard, same run and environment: keeps its ok against the frozen base " .. FROZEN:sub(1, 9))
    else bad("fixed guard refused with the base frozen (rc=" .. rc .. "): " .. o:sub(1, 200)) end
    fs.write(REL .. "/repo/scripts/added.sh", PIPE)
    rc, o = run_guard(ROOT .. "/" .. GUARD)
    if rc ~= 0 and has(o, "added.sh") then ok("fixed guard still refuses a pipeline the change really adds (added.sh)")
    else bad("fixed guard missed an added pipeline (rc=" .. rc .. "): " .. o:sub(1, 200)) end
end

-- 4: the gate and the hook freeze it, at the right points.
local build = fs.read("build.sh") or ""
local hook = fs.read("scripts/hooks/pre-push-local-gate.sh") or ""
local after_fetch = build:match("fetch %-q origin 2>/dev/null || true\n%s*_freeze_gate_diff_base || exit 1") ~= nil
if has(build, 'if [[ "$FLAG_PREFLIGHT" != true ]]; then _freeze_gate_diff_base || exit 1; fi') and after_fetch
    and has(hook, "TILLANDSIAS_GATE_DIFF_BASE=\"$(git merge-base HEAD origin/linux-next")
    and has(hook, "refused:gate-diff-base:inherited-not-ancestor:") and has(hook, "note:gate-diff-base:other-checkout:") then
    ok("build.sh freezes the base before any guard (preflight after its fetch); the pre-push hook freezes first and refuses a foreign inherited base")
else
    bad("the gate or the hook no longer freezes the diff base where it must")
end

-- 4b: build.sh's own function (between its markers), run in the scratch repo
-- whose HEAD is `work`: an inherited ancestor is kept, a base frozen for
-- another branch (B, trunk's fix, not an ancestor of work) is refused by name,
-- and with nothing inherited the base is frozen here at A.
local fn = build:match("# BEGIN%-GATE%-DIFF%-BASE\n(.-)# END%-GATE%-DIFF%-BASE")
if not fn then
    bad("build.sh lost its BEGIN/END-GATE-DIFF-BASE markers")
else
    -- $3 is where the inherited base was frozen: `self` (this repo), a path, or
-- `unset`. Set explicitly, never inherited: under the gate the environment
-- carries the real checkout's root.
    fs.write(REL .. "/tools/freeze.sh", "SCRIPT_DIR=\"$1\"\n" .. fn .. "\nif [ \"$2\" = unset ]; then unset TILLANDSIAS_GATE_DIFF_BASE; else export TILLANDSIAS_GATE_DIFF_BASE=\"$2\"; fi\ncase \"$3\" in unset) unset TILLANDSIAS_GATE_DIFF_BASE_ROOT ;; self) export TILLANDSIAS_GATE_DIFF_BASE_ROOT=\"$(git -C \"$1\" rev-parse --show-toplevel)\" ;; *) export TILLANDSIAS_GATE_DIFF_BASE_ROOT=\"$3\" ;; esac\n_freeze_gate_diff_base\necho \"rc=$? base=${TILLANDSIAS_GATE_DIFF_BASE:-}\"\n")
    local function freeze(inherited, root)
        local r = proc.run({ argv = { "bash", S .. "/tools/freeze.sh", REPO, inherited, root }, timeout_ms = 30000 })
        return (r.stdout or "") .. (r.stderr or "")
    end
    local kept, stale, fresh = freeze(A, "self"), freeze(B, "self"), freeze("unset", "unset")
    local other = freeze(B, "/elsewhere/another-checkout")
    if has(kept, "note:gate-diff-base:inherited:" .. A) and has(kept, "rc=0")
        and has(stale, "refused:gate-diff-base:inherited-not-ancestor:" .. B) and has(stale, "rc=1")
        and has(fresh, "note:gate-diff-base:frozen:" .. A) and has(fresh, "rc=0 base=" .. A)
        and has(other, "note:gate-diff-base:other-checkout:/elsewhere/another-checkout") and has(other, "rc=0 base=" .. A) then
        ok("an inherited ancestor is kept (note names inherited); a stale base from another branch is refused by name; unset freezes here at A; a base frozen for another checkout is set aside and this repo freezes its own")
    else
        bad("freeze outcomes — kept: " .. kept:sub(1, 120) .. " | stale: " .. stale:sub(1, 120) .. " | fresh: " .. fresh:sub(1, 120) .. " | other: " .. other:sub(1, 120))
    end
end

-- 5: the population of live-ref diff bases, and each one's fallback.
-- check-landing-provenance reads trunk's own history (REF), not a diff base.
local EXEMPT = { ["scripts/check-landing-provenance.sh"] = true }
local sites, unfrozen, searched = {}, {}, 0
local function scan(dir, suffix)
    for _, f in ipairs(fs.walk(dir)) do
        local name = f:match("[^/]+$") or f
        if f:sub(-#suffix) == suffix and not name:match("^test%-") and not EXEMPT[f] then
            searched = searched + 1
            local okr, body = pcall(fs.read, f)
            if okr and body then
                local n = 0
                for line in body:gmatch("[^\n]+") do
                    local code = line:match("^%s*(.-)%s*$")
                    if not code:match("^#") and not code:match("^%-%-") then
                        local live = code:find(":-origin/linux-next}", 1, true) or code:find('BASE = "origin/linux-next"', 1, true)
                            or code:find("origin/linux-next...HEAD", 1, true) or code:find("origin/linux-next}\"...HEAD", 1, true)
                        if live then
                            n = n + 1
                            local frozen = has(code, "TILLANDSIAS_GATE_DIFF_BASE")
                                or (suffix == ".lua" and has(body, 'env.get("TILLANDSIAS_GATE_DIFF_BASE")'))
                            sites[#sites + 1] = f .. (frozen and "" or " (UNFROZEN)")
                            if not frozen then unfrozen[#unfrozen + 1] = f end
                        end
                    end
                end
            end
        end
    end
end
scan("scripts", ".sh")
scan("scripts/lua", ".lua")
table.sort(sites)
for _, s in ipairs(sites) do out.line("  diff-base: " .. s) end
if #sites >= 20 and #unfrozen == 0 then
    ok("population=" .. #sites .. " live-ref diff bases in " .. searched .. " files; every one falls back through TILLANDSIAS_GATE_DIFF_BASE")
else
    bad("population=" .. #sites .. " unfrozen=" .. #unfrozen .. ": " .. table.concat(unfrozen, ", "))
end

proc.run({ argv = { "rm", "-rf", S } })
if failed == 0 then verdict.emit("ok:gate-diff-base-frozen-fixture:" .. passed, 0) end
verdict.emit("refused:gate-diff-base-frozen-fixture:" .. failed, 1)
