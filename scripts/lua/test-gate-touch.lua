-- @trace order:1599-egzz
--
-- test-gate-touch.lua — every gate build.sh runs touches the gating
-- checkout's tracked files before any cargo, so a CARGO_TARGET_DIR shared by
-- several worktrees cannot serve another checkout's units as fresh (cargo's
-- path-package freshness is mtime only). The end-to-end A/B source probe
-- through ./build.sh --test is recorded on the row; this fixture pins the
-- wiring it depends on, cheaply, on every gate.
--
--   1 PLACEMENT  the touch runs right after the 1592 base freeze, before the
--                --preflight door and before any cargo invocation in build.sh
--   2 MODES      it runs for --check, --test, --ci, --ci-full, --release and
--                --install, and not for --preflight or a plain dev build
--   3 BEHAVIOUR  build.sh's own function, run in a scratch repo, moves the
--                mtime of every tracked file (including one outside crates/)
--                and leaves an untracked file alone
--
-- Terminal line: ok:gate-touch-fixture:<n> or refused:gate-touch-fixture:<failed>.
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-touch.lua

local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local REL = "target/plan-scratch/gate-touch-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local S = ROOT .. "/" .. REL
local passed, failed = 0, 0
local function ok(m) out.line("ok: " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL: " .. m); failed = failed + 1 end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end

local build = fs.read("build.sh") or ""
local block = build:match("# BEGIN%-GATE%-TOUCH\n(.-)# END%-GATE%-TOUCH")
if not block then
    bad("build.sh lost its BEGIN/END-GATE-TOUCH markers")
    verdict.emit("refused:gate-touch-fixture:" .. failed, 1)
end

-- 1: placement.
local freeze = build:find('if [[ "$FLAG_PREFLIGHT" != true ]]; then _freeze_gate_diff_base || exit 1; fi', 1, true)
local touch = build:find("# BEGIN-GATE-TOUCH", 1, true)
local door = build:find('if [[ "$FLAG_PREFLIGHT" == true ]]; then', 1, true)
local first_cargo = build:find("\n%s*_run cargo ") or build:find("\n%s*%(cd \"%$SCRIPT_DIR\" && cargo ")
if freeze and touch and door and first_cargo and freeze < touch and touch < door and touch < first_cargo then
    ok("the touch follows the 1592 base freeze and precedes the preflight door and the first cargo invocation")
else
    bad("placement: freeze=" .. tostring(freeze) .. " touch=" .. tostring(touch) .. " door=" .. tostring(door) .. " first_cargo=" .. tostring(first_cargo))
end

-- 2: modes.
local cond = block:match('if %[%[ "([^"]+)" == %*true%* %]%]; then\n%s*%(cd "%$SCRIPT_DIR" && _touch_gating_checkout%)')
local want = { "FLAG_CHECK", "FLAG_TEST", "FLAG_CI", "FLAG_CI_FULL", "FLAG_RELEASE", "FLAG_INSTALL" }
local missing = {}
for _, f in ipairs(want) do
    if not (cond and has(cond, "$" .. f .. "$") or (cond and cond:sub(-#f - 1) == "$" .. f)) then missing[#missing + 1] = f end
end
if cond and #missing == 0 and not has(cond, "FLAG_PREFLIGHT") then
    ok("it runs for --check/--test/--ci/--ci-full/--release/--install, not --preflight (" .. cond .. ")")
else
    bad("modes: condition=" .. tostring(cond) .. " missing=" .. table.concat(missing, ","))
end

-- 3: behaviour, build.sh's own function in a scratch repo.
local fn = block:match("(_touch_gating_checkout%(%) {.-\n})")
fs.mkdir(REL .. "/repo/crates/x/src")
fs.mkdir(REL .. "/repo/images/default")
fs.write(REL .. "/repo/crates/x/src/lib.rs", "pub fn x() {}\n")
fs.write(REL .. "/repo/images/default/embedded.txt", "embedded\n")
fs.write(REL .. "/repo/untracked.txt", "not tracked\n")
local function git(args)
    local argv = { "git", "-C", S .. "/repo", "-c", "user.name=fixture", "-c", "user.email=fixture@local", "-c", "commit.gpgsign=false" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    proc.run({ argv = argv, timeout_ms = 30000 })
end
git({ "init", "-q" }); git({ "add", "crates", "images" }); git({ "commit", "-qm", "fixture" })
-- Age every file, so a touch is visible as a move forward.
proc.run({ argv = { "touch", "-d", "2001-01-01 00:00:00", S .. "/repo/crates/x/src/lib.rs", S .. "/repo/images/default/embedded.txt", S .. "/repo/untracked.txt" } })
fs.write(REL .. "/run.sh", "SCRIPT_DIR=\"$1\"\n" .. (fn or "") .. "\ncd \"$1\" && _touch_gating_checkout\nstat -c '%Y %n' crates/x/src/lib.rs images/default/embedded.txt untracked.txt\n")
local r = proc.run({ argv = { "bash", S .. "/run.sh", S .. "/repo" }, timeout_ms = 30000 })
local o = r.stdout or ""
local old = 978307200 + 86400 * 2 -- well after 2001-01-01, as a floor
local m = {}
for t, n in o:gmatch("(%d+) ([^\n]+)") do m[n] = tonumber(t) end
local lib, emb, unt = m["crates/x/src/lib.rs"], m["images/default/embedded.txt"], m["untracked.txt"]
if fn and lib and emb and unt and lib > old and emb > old and unt < old and has(r.stderr or "", "note:gate-touch:") then
    ok("build.sh's function moves every tracked file's mtime (crates/ and images/) and leaves an untracked file alone")
else
    bad("behaviour: fn=" .. tostring(fn ~= nil) .. " out=" .. o:gsub("\n", " | ") .. " err=" .. (r.stderr or ""):sub(1, 120))
end

proc.run({ argv = { "rm", "-rf", S } })
if failed == 0 then verdict.emit("ok:gate-touch-fixture:" .. passed, 0) end
verdict.emit("refused:gate-touch-fixture:" .. failed, 1)
