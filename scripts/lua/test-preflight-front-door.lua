-- @trace order:1305-udgs, order:2272-cuxh, order:2404-grd6
-- @env PATH HOME USER LOGNAME TOOLBOX_PATH container TILLANDSIAS_SKIP_TOOLBOX TILLANDSIAS_SHARED_TARGET_HELD TILLANDSIAS_SHARED_TARGET CARGO_TARGET_DIR TILLANDSIAS_FRONT_DOOR_LIVE TILLANDSIAS_PREFLIGHT_BUDGET_S
--
-- test-preflight-front-door.lua — the preflight front door (`./build.sh --preflight`) cannot lie.
-- Ported from test-preflight-front-door.sh (2404-grd6); the same arms, in its order. Each
-- reproduces a defect the door actually had (pirria, 2026-09-20).
--
--   1  ENUMERATION: the roster scans FAST REFUSALS, gate-steps.d and scripts/hooks, as literals,
--      with no list variable between the tier and the door (1063-nraf)
--   2  RUN OR NAMED: a guard planted in gate-steps.d is picked up and refuses
--   2b its refusal names a why and a remedy command that, executed, reproduces the verdict (1515-iwb3)
--   2c a guard build.sh runs INLINE is picked up, and run with the gate's arguments (1499-m9fj)
--   2g a declared gate-only fixture is a named skip and not run; a reasonless declaration and a
--      push decider's declaration are not honoured (1496-w25b)
--   2d a serial guard runs with nothing beside it, with the concurrency PREMISE (1499-m9fj)
--   3  a named skip is not a refusal (1273-4mak)
--   4  every guard runs with stdin from /dev/null
--   5  the dispatch precedes the dev-proxy setup
--   6  the settled door completes inside its regime's budget (1616-njfd, 2280-vzsr)
--   7  --full exists and drops the deadline
--   8  the door adds no surviving guard children
--   9  a deadline skip reports its MEASURED cost
--   W  the live checkout's status and build.sh never moved during the run (1516-wru4)
--
-- LIVE ONLY (2272-cuxh): the door runs several times (14-44 min by host), so only the land
-- queue's --daily-full gate runs it, with TILLANDSIAS_FRONT_DOOR_LIVE=1. Without it the fixture
-- prints not-run:preflight-front-door and skips by name. Every door below runs with that switch
-- UNSET, so the door never starts this fixture inside itself.
--
-- NEVER IN THE LIVE CHECKOUT (1516-wru4): the arms plant guards and steps and append to
-- build.sh, so they run in a scratch clone of HEAD, overlaid with the live tracked edits. A
-- sampler watches the live checkout the whole run. The scratch is a `git clone --shared` under
-- kit scratch, not a worktree of the live checkout (the .sh's `git worktree add`).
--
-- WHAT THE DOOR RUNS: build.sh's own roster (fast refusals, gate steps, hook checks, inline
-- deciders), the same guards the gate runs on this host. It never runs the relay preflight's
-- unreferenced-fixture sweep, so scripts/test-macos-vsock-inference-closure.sh (which drives the
-- macOS VM, 2399-vsok) is not in it; arm R below refuses the run if the roster ever names it.
--
-- GRAMMAR ok:preflight-front-door:<n> arms | violation:preflight-front-door:<n>-failed
--       | skip:preflight-front-door:not-live | could-not-run:preflight-front-door:<why>

local fixture = require "common.fixture"
local T = fixture.new("preflight-front-door")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()

local function getenv(k) local ok, v = pcall(env.get, k); return ok and v or nil end
if getenv("TILLANDSIAS_FRONT_DOOR_LIVE") ~= "1" then
    out.line("not-run:preflight-front-door — runs on the --daily-full gate; here: TILLANDSIAS_FRONT_DOOR_LIVE=1 tillandsias-plan script run scripts/lua/test-preflight-front-door.lua (2272-cuxh)")
    T:skip("not-live")
end

local PLAN = fixture.plan_binary()
if PLAN == "" then
    verdict.emit("could-not-run:preflight-front-door:no-plan-binary", 3,
        "  why: the doors below could classify no guard\n  remedy: cargo build --release -p tillandsias-plan, then re-run")
end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end

-- 1943-fdsb: ask the binary the door asks, before any arm runs the door. A stale one makes
-- the door refuse before any guard runs, which says nothing about the door.
local vs = T:run{ PLAN, "validator-surface-hash", "--check", cwd = ROOT, timeout_ms = 60000 }
local vso = (vs.stdout or "") .. (vs.stderr or "")
if text.contains(vso, "stale:validator-surface") then
    verdict.emit("could-not-run:preflight-front-door:stale-plan-binary", 3,
        "  why: the door refuses before any guard runs, so no arm here can observe it (" .. PLAN .. ")\n"
        .. "  remedy: cargo build --release -p tillandsias-plan && bash scripts/check-plan-binary-current.sh, then re-run")
end

-- ── The scratch clone, overlaid with the live tracked edits ─────────────────────────────────
local W = T:scratch("front-door")
local SCR, SCR_REL = W.abs .. "/tree", W.rel .. "/tree"
local head = text.trim(T:must{ "git", "rev-parse", "HEAD", cwd = ROOT }.stdout or "")
T:must{ "git", "clone", "-q", "--shared", "--no-checkout", ROOT, SCR, cwd = ROOT, timeout_ms = 300000 }
T:must{ "git", "-C", SCR, "checkout", "-q", "--detach", head, timeout_ms = 300000 }
fs.write(W.rel .. "/overlay.sh", [[
cd "$1" || exit 1
git diff --name-only HEAD | while IFS= read -r f; do
    if [ -e "$f" ]; then mkdir -p "$2/$(dirname "$f")"; cp -p "$f" "$2/$f"; else rm -f "$2/$f"; fi
done
mkdir -p "$2/target/release" && cp -p "$3" "$2/target/release/$(basename "$3")"
]])
local ov = T:run{ SH, W.abs .. "/overlay.sh", ROOT, SCR, PLAN, cwd = ROOT, timeout_ms = 600000 }
if ov.code ~= 0 then T:refuse("scratch-overlay-failed", (ov.stdout or "") .. (ov.stderr or "")) end

-- The sampler watches the live checkout for the whole run (1516-wru4).
local MOVED, STOP = W.abs .. "/moved", W.abs .. "/sampler-stop"
fs.write(W.rel .. "/sampler.sh", [[
root=$1; marker=$2; stop=$3
live() { git -C "$root" status --porcelain; cksum < "$root/build.sh"; }
before="$(live)"
while [ ! -e "$stop" ]; do
    now="$(live)"
    if [ "$now" != "$before" ] && [ ! -e "$marker" ]; then
        { date +%T; printf 'before:\n%s\nnow:\n%s\n' "$before" "$now"; } > "$marker"
    fi
    sleep 1
done
]])
local live_before = text.trim((T:run{ "git", "status", "--porcelain", cwd = ROOT }.stdout or ""))
    .. "|" .. text.trim((T:run{ "cksum", ROOT .. "/build.sh" }.stdout or ""):match("^(%S+)") or "")
local sampler = proc.spawn{ argv = { SH, W.abs .. "/sampler.sh", ROOT, MOVED, STOP }, cwd = ROOT, timeout_ms = 7200000 }

-- ── The door, as a host runs it ──────────────────────────────────────────────────────────────
-- PATH without the litmus runner's podman shim (1496-w25b); the gate's toolbox and shared-target
-- guards carried (land runs 79 and 82); the live switch never reaches a nested door; the bench
-- off except for the budget arm's private record (2280-vzsr).
local path = {}
for p in ((getenv("PATH") or "") .. ":"):gmatch("([^:]*):") do
    if p ~= "" and not p:find("/target/litmus%-runtime/bin$") then path[#path + 1] = p end
end
local BASE = { PATH = table.concat(path, ":"), TILLANDSIAS_PREFLIGHT_BENCH = "off" }
for _, k in ipairs{ "USER", "LOGNAME" } do BASE[k] = getenv(k) end
fixture.gate_inherit(BASE)
local UNSET = { "TILLANDSIAS_FRONT_DOOR_LIVE", "FRONT_DOOR_SCRATCH", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
    "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_PREFIX" }
local function door(extra)
    local e = {}
    for k, v in pairs(BASE) do e[k] = v end
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = T:run{ "./build.sh", "--preflight", cwd = SCR, env = e, env_unset = UNSET, timeout_ms = 3600000 }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local function lines(s) return text.lines(s or "") end
local function has_line(s, want) for _, l in ipairs(lines(s)) do if l == want then return true end end return false end
local function plant(rel, body) fs.write(SCR_REL .. "/" .. rel, body); T:must{ "chmod", "+x", SCR .. "/" .. rel } end
local function rm(...) local a = { "rm", "-f" }; for _, p in ipairs{ ... } do a[#a + 1] = SCR .. "/" .. p end; T:must(a) end
local function step_for(paths)
    local b = {}
    for _, p in ipairs(paths) do b[#b + 1] = 'STEP_DESC="planted"\nSTEP_SCRIPT="' .. p .. '"\nSTEP_ERROR="planted"\nSTEP_OK="planted"\n' end
    return table.concat(b)
end
local function tail(s, pat, n)
    local got = {}
    for _, l in ipairs(lines(s)) do if l:find(pat) then got[#got + 1] = l end end
    local from = math.max(1, #got - (n or 4) + 1)
    return table.concat(got, "|", from)
end

-- Orphan baseline BEFORE this fixture runs the door: the claim is a DELTA.
local ORPHAN_PAT = "test-token-instrument|test-memo-hit-observability"
local function orphans()
    local r = T:run{ "pgrep", "-f", ORPHAN_PAT }
    local n = 0
    for _, l in ipairs(lines(r.stdout)) do if l:match("^%d+$") then n = n + 1 end end
    return n
end
local orphans_before = orphans()

local BUILD = fs.read(SCR_REL .. "/build.sh") or ""

-- ── ARM 1: ENUMERATION, not curation ───────────────────────────────────────────────────────
local roster_fn = BUILD:match("\n(_preflight_roster%(%) {\n.-\n}\n)") or ""
for _, r in ipairs{ "FAST REFUSALS", "gate-steps.d", "scripts/hooks" } do
    T:arm("1 the roster scans " .. r, text.contains(roster_fn, r), "roster bytes=" .. #roster_fn)
end
T:arm("1 the roster scans literal bindings, with no list variable to drift from (1063-nraf)",
    roster_fn ~= "" and not text.contains(roster_fn, "_fast_refusal_checks"), "roster bytes=" .. #roster_fn)

-- ── ARM R (safety): the door's roster names no VM-driving fixture ──────────────────────────
fs.write(W.rel .. "/roster.sh", 'cd "$1" && SCRIPT_DIR="$1" && eval "$(awk \'/^_preflight_roster\\(\\) \\{/,/^\\}/\' build.sh)" && _preflight_roster\n')
local rr = T:run{ SH, W.abs .. "/roster.sh", SCR, cwd = SCR, env_unset = { "TILLANDSIAS_PREFLIGHT_ROSTER_FILE" }, timeout_ms = 60000 }
local roster_out = rr.stdout or ""
T:arm("R the door's roster names no VM-driving fixture (test-macos-vsock-inference-closure, 2399-vsok)",
    rr.code == 0 and #lines(roster_out) > 50 and not text.contains(roster_out, "macos-vsock-inference-closure"),
    "rc=" .. tostring(rr.code) .. " entries=" .. #lines(roster_out))
if text.contains(roster_out, "macos-vsock-inference-closure") then
    fs.write(W.rel .. "/sampler-stop", ""); sampler:wait()
    T:refuse("roster-drives-the-vm", "the door's roster names test-macos-vsock-inference-closure; not running a door that would start the VM")
end

-- ── ARM 2: RUN OR NAMED — no silent third state ────────────────────────────────────────────
plant("scripts/check-zz-1305-planted.sh", '#!/usr/bin/env bash\necho "violation:planted-guard: this guard exists and refuses"\nexit 1\n')
fs.write(SCR_REL .. "/scripts/gate-steps.d/999-zz-1305-planted.step", step_for{ "scripts/check-zz-1305-planted.sh" })
local rc, o = door{ TILLANDSIAS_PREFLIGHT_TIMEOUT = "5" }
T:arm("2 a guard wired into gate-steps.d is picked up and refuses (no silent third state)",
    rc ~= 0 and text.contains(o, "zz-1305-planted"),
    "rc=" .. tostring(rc) .. " bytes=" .. #o .. " " .. tail(o, "zz%-1305|:preflight:ran="))
-- ARM 2b (1515-iwb3): the refusal's remedy runs and reproduces the guard's verdict.
local remedy = nil
local ls = lines(o)
for i, l in ipairs(ls) do
    if text.contains(l, "the guard check-zz-1305-planted refused") then
        for j = i, math.min(i + 1, #ls) do
            remedy = remedy or ls[j]:match("confirm with the guard alone: bash (%S+)")
        end
    end
end
if text.contains(o, "  why: the guard check-zz-1305-planted refused this tree") and remedy then
    local again = T:run{ SH, remedy, cwd = SCR, timeout_ms = 60000 }
    T:arm("2b the refusal names its why and a remedy command that, executed (bash " .. remedy .. "), reproduces the guard's verdict",
        again.code ~= 0 and text.contains(again.stdout or "", "violation:planted-guard"), "rc=" .. tostring(again.code))
else
    T:arm("2b the per-guard refusal carries a why and a remedy with a runnable command", false, tail(o, "zz%-1305", 6))
end
rm("scripts/check-zz-1305-planted.sh", "scripts/gate-steps.d/999-zz-1305-planted.step")

-- ── ARM 2c: A GUARD THE GATE RUNS INLINE IS A ROSTER ENTRY (1499-m9fj), IN THE GATE'S MODE ──
plant("scripts/check-zz-1499-args.sh", '#!/usr/bin/env bash\nif [ "${1:-}" = zzmode ] && [ "${2:-}" = second ]; then\n'
    .. '    echo "violation:planted-mode-guard: refuses only in the gate\'s mode"\n    exit 1\nfi\n'
    .. 'echo "ok:planted-mode-guard: no mode given (argv: $*)"\n')
plant("scripts/check-zz-1499-planted.sh", '#!/usr/bin/env bash\necho "violation:planted-inline-guard: this guard exists and refuses"\nexit 1\n')
T:must{ "cp", "-p", SCR .. "/build.sh", W.abs .. "/build.sh.1499" }
fs.write(W.rel .. "/frag-1499", '\n_zz_1499_never_called() {\n    _run bash "$SCRIPT_DIR/scripts/check-zz-1499-planted.sh"\n'
    .. '    _run bash "$SCRIPT_DIR/scripts/check-zz-1499-args.sh" zzmode second 2>&1\n}\n')
fs.write(W.rel .. "/append.sh", 'cat "$1" >> "$2"\n')
T:must{ SH, W.abs .. "/append.sh", W.abs .. "/frag-1499", SCR .. "/build.sh" }
rc, o = door{ TILLANDSIAS_PREFLIGHT_TIMEOUT = "5" }
T:arm("2c a guard build.sh runs inline is picked up and refuses (1499-m9fj)",
    rc ~= 0 and text.contains(o, "zz-1499-planted"), "rc=" .. tostring(rc) .. " " .. tail(o, "zz%-1499|:preflight:ran="))
T:arm("2c the door runs an inline guard in the gate's mode, with the gate's arguments (1499-m9fj)",
    has_line(o, "refused:preflight:check-zz-1499-args[zzmode second]") and text.contains(o, "violation:planted-mode-guard"),
    tail(o, "zz%-1499"))
T:must{ "cp", "-p", W.abs .. "/build.sh.1499", SCR .. "/build.sh" }
rm("scripts/check-zz-1499-planted.sh", "scripts/check-zz-1499-args.sh")

-- ── ARM 2g: A SELF-DECLARED GATE-ONLY GUARD (1496-w25b) ────────────────────────────────────
local GO_MARK = W.abs .. "/gate-only-ran"
local function plant_go(rel, decl)
    plant(rel, "#!/usr/bin/env bash\n" .. decl .. '\ntouch "' .. GO_MARK .. '.$(basename "$0")"\nexit 0\n')
end
local GO_A, GO_B, GO_C = "scripts/test-zz-1496-gate-only.sh", "scripts/test-zz-1496-gate-only-bare.sh", "scripts/check-zz-1496-gate-only-decider.sh"
plant_go(GO_A, "# preflight: gate-only — runs the planted fixture harness end to end")
plant_go(GO_B, "# preflight: gate-only")
plant_go(GO_C, "# preflight: gate-only — a decider claiming it")
fs.write(SCR_REL .. "/scripts/gate-steps.d/999-zz-1496-gate-only.step", step_for{ GO_A, GO_B, GO_C })
rc, o = door{ TILLANDSIAS_PREFLIGHT_TIMEOUT = "5" }
local function ran(base) return fs.exists(W.rel .. "/gate-only-ran." .. base) end
T:arm("2g a declared gate-only fixture is a named declared skip and is not run",
    has_line(o, "skip:preflight:test-zz-1496-gate-only:gate-only — runs the planted fixture harness end to end")
        and not ran("test-zz-1496-gate-only.sh"), tail(o, "zz%-1496"))
T:arm("2g NEGATIVE CONTROL: a declaration with no reason is not honoured; the guard runs",
    ran("test-zz-1496-gate-only-bare.sh") and text.contains(o, "test-zz-1496-gate-only-bare:gate-only-without-a-reason"), tail(o, "zz%-1496"))
T:arm("2g NEGATIVE CONTROL: a push decider cannot declare itself gate-only; it runs",
    ran("check-zz-1496-gate-only-decider.sh") and text.contains(o, "check-zz-1496-gate-only-decider:gate-only-ignored"), tail(o, "zz%-1496"))
rm(GO_A, GO_B, GO_C, "scripts/gate-steps.d/999-zz-1496-gate-only.step")

-- ── ARM 2d: A SERIAL GUARD RUNS WITH NOTHING BESIDE IT (1499-m9fj) ─────────────────────────
local SER_LOG = W.abs .. "/serial.log"
fs.write(W.rel .. "/serial.log", "")
local function plant_ser(rel, tag, decl)
    plant(rel, "#!/usr/bin/env bash\n" .. decl .. '\necho "' .. tag .. ' start" >> "' .. SER_LOG .. '"\nsleep 2\necho "'
        .. tag .. ' end" >> "' .. SER_LOG .. '"\n')
end
local SA, SB, SC = "scripts/test-zz-1499-serial-a.sh", "scripts/test-zz-1499-serial-b.sh", "scripts/test-zz-1499-serial-c.sh"
plant_ser(SA, "A", "# preflight: serial — planted: writes the shared log alone")
plant_ser(SB, "B", "")
plant_ser(SC, "C", "")
fs.write(SCR_REL .. "/scripts/gate-steps.d/999-zz-1499-serial.step", step_for{ SA, SB, SC })
door{ TILLANDSIAS_PREFLIGHT_JOBS = "3", TILLANDSIAS_PREFLIGHT_TIMEOUT = "5" }
local ser = fs.read(W.rel .. "/serial.log") or ""
-- overlaps(x, y): an interval test, never a string pattern (`B start A end C start B end`).
local function overlaps(x, y)
    local open, o_ = {}, false
    for _, l in ipairs(lines(ser)) do
        local who, what = l:match("^(%a) (%a+)$")
        if what == "start" then
            if (who == x and open[y]) or (who == y and open[x]) then o_ = true end
            open[who] = true
        elseif what == "end" then open[who] = false end
    end
    return o_
end
local flat = ser:gsub("\n", " ")
T:arm("2d PREMISE: undeclared plants B and C ran concurrently", overlaps("B", "C"), flat)
T:arm("2d a guard declaring serial ran with nothing beside it",
    not overlaps("A", "B") and not overlaps("A", "C") and has_line(ser, "A end"), flat)
rm(SA, SB, SC, "scripts/gate-steps.d/999-zz-1499-serial.step")

-- ── ARM 3: A NAMED SKIP IS NOT A REFUSAL (1273-4mak, 1384-bqhy) ───────────────────────────
local skip_case = false
for _, l in ipairs(lines(BUILD)) do if l:match("^%s+skip%)$") then skip_case = true end end
T:arm("3 a skip: line is treated as a skip whatever the guard exits with",
    text.contains(BUILD, '_pf_kind="$(_pf_classify "$_pf_rc" "$_pf_tmp")"') and skip_case
        and text.contains(BUILD, "_pf_declskip=$((_pf_declskip + 1)) ;;"), "")

-- ── ARM 4: EVERY GUARD RUNS WITH STDIN CLOSED ─────────────────────────────────────────────
T:arm("4 guards run with stdin from /dev/null (the door cannot eat its worklist)", text.contains(BUILD, "</dev/null"), "")

-- ── ARM 5: THE DISPATCH IS BEFORE ANY SETUP ───────────────────────────────────────────────
local door_ln, proxy_ln
for i, l in ipairs(lines(BUILD)) do
    if not door_ln and text.contains(l, 'FLAG_PREFLIGHT" == true') then door_ln = i end
    if not proxy_ln and text.contains(l, "Starting dev proxy container") then proxy_ln = i end
end
T:arm("5 the dispatch precedes the dev-proxy setup (no containers, no sidecar)",
    door_ln ~= nil and proxy_ln ~= nil and door_ln < proxy_ln, "door=" .. tostring(door_ln) .. " proxy=" .. tostring(proxy_ln))

-- ── ARM 6: THE WALL-CLOCK BUDGET IS THE CONTRACT (1305-udgs, 1616-njfd, 2280-vzsr) ─────────
-- The floor 150 s unless the summary names its regime's budget; TILLANDSIAS_PREFLIGHT_BUDGET_S
-- wins. Door 1 inside its budget passes; otherwise two more doors run on one private bench
-- record and door 3 is judged. An over-budget door 3 that benched nothing on a contended host
-- measured the load: named not-judged, never a pass.
local J = require("common.preflight_judge")
local OVERRIDE = getenv("TILLANDSIAS_PREFLIGHT_BUDGET_S")
if OVERRIDE == "" then OVERRIDE = nil end
local BENCH = W.abs .. "/bench-record.tsv"
local function budget_door()
    -- Where only the START load is readable (no /proc), wait out the door before, at most 300 s.
    J.settle_start_load(300, { run = function(a) return T:run(a) end, sleep = function(n) T:run{ "sleep", tostring(n) } end })
    local _, o_ = door{ TILLANDSIAS_PREFLIGHT_BENCH = "on", TILLANDSIAS_PREFLIGHT_BENCH_FILE = BENCH }
    return o_
end
local kind, msg = J.settled(budget_door, OVERRIDE)
if kind == "not-judged" then
    out.line(msg)
else
    T:arm("6 the whole run completes inside the budget (judged by common.preflight_judge)", kind == "ok", msg)
end
out.line("budget: " .. msg)

-- ── ARM 7: --full removes the deadline, and says so ─────────────────────────────────────────
T:arm("7 --full runs the same enumeration with no deadline",
    text.contains(BUILD, "FLAG_PREFLIGHT_FULL") and text.contains(BUILD, "deadline"), "")

-- ── ARM 8: THE DOOR LEAVES NO ORPHANS ─────────────────────────────────────────────────────
local orphans_after = orphans()
T:arm("8 the door adds no surviving guard children (before=" .. orphans_before .. " after=" .. orphans_after .. ")",
    orphans_after <= orphans_before, "new orphans: " .. (orphans_after - orphans_before))

-- ── ARM 9: THE SKIP LINE CARRIES THE MEASURED COST ─────────────────────────────────────────
T:arm("9 a deadline skip reports its MEASURED cost, so a deadline that fails to bound is visible",
    text.contains(BUILD, "deadline:$(( SECONDS - _pf_t0 ))s"), "")

-- ── ARM W: the live checkout never moved (1516-wru4) ─────────────────────────────────────
fs.write(W.rel .. "/sampler-stop", "")
sampler:wait()
local live_after = text.trim((T:run{ "git", "status", "--porcelain", cwd = ROOT }.stdout or ""))
    .. "|" .. text.trim((T:run{ "cksum", ROOT .. "/build.sh" }.stdout or ""):match("^(%S+)") or "")
local moved = fs.exists(W.rel .. "/moved") and fs.read(W.rel .. "/moved") or nil
T:arm("W the live checkout's status and build.sh never moved during the run (1516-wru4)",
    live_after == live_before and moved == nil, (moved or "") .. " before=" .. live_before .. " after=" .. live_after)

T:finish()
