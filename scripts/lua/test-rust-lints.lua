-- @trace order:1631-6w8z
-- @env PATH TILLANDSIAS_SCRIPT_RUNNER_BIN
-- preflight: own-deadline — compiles a scratch crate with cargo clippy (cold, 5-30 s), past the 5 s guard deadline
--
-- test-rust-lints.lua — the preflight door asks the gate's cargo fmt and
-- clippy refusals (1631-6w8z), and a slow answer is a deadline skip, never a
-- refusal.
--
-- scripts/lua/check-rust-lints.lua is run against a SCRATCH cargo workspace
-- (its own [workspace], its own git history, its own CARGO_TARGET_DIR under
-- target/plan-scratch), never this checkout's crates. build.sh's door
-- functions are EXTRACTED at run time, not copied.
--   1 FMT-OK      a formatted crate: ok:rust-fmt
--   2 FMT-HIT     one unformatted hunk: refused:rust-fmt naming the file
--   3 UNTOUCHED   a change outside crates/: skip, and no cargo ran (the
--                 scratch target dir was never created)
--   4 CLIPPY-HIT  collapsible_if in a touched crate: refused:rust-clippy
--                 naming the package and the lint, exit 1
--   5 CLIPPY-OK   the touched crate, clean: ok:rust-clippy:<package>
--   6 ROSTER      the door's roster carries both modes; the same function
--                 without source 6 (the trunk door, constructed) carries
--                 neither, (trunk asked no fmt and no
--                 clippy at the door: none of its five sources is a cargo command)
--   7 DEADLINE    an own-deadline guard that outlives the lane deadline ends
--                 rc 124, which the classifier books timed-out (a deadline
--                 skip), never refused
--   8 BUDGET      with no override the lane deadline is what is left of the
--                 door's budget; under --full it is 0 (none)
--   9 NO-REASON   a bare own-deadline declaration is not honoured: the guard
--                 is run under the per-guard deadline, with a note
--  10 LAUNCHER   the roster launcher does not ALSO start an own-deadline
--                 guard (two runs would race on one rc file)
--
-- Usage: tillandsias-plan script run scripts/lua/test-rust-lints.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("rust-lints-fixture", "git rev-parse --show-toplevel did not answer")
end
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if PLAN == "" then
    verdict.could_not_run("rust-lints-fixture", "TILLANDSIAS_SCRIPT_RUNNER_BIN is unset, so the guard cannot be run")
end
local probe = proc.run({ argv = { "cargo", "clippy", "--version" }, cwd = ROOT, timeout_ms = 60000 })
if probe.status ~= "exited" or probe.code ~= 0 then
    verdict.skip("rust-lints-fixture", "no-cargo-clippy")
end

local REL = "target/plan-scratch/rust-lints-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local A = ROOT .. "/" .. REL
fs.mkdir(REL)

local failed = {}
local function arm(name, cond, got)
    got = tostring(got):gsub("\n", " | ")
    if cond then out.line("ok:   " .. name .. " — " .. got) else
        out.line("FAIL: " .. name .. " — got: " .. got)
        failed[#failed + 1] = name
    end
end

-- ── the scratch workspace ───────────────────────────────────────────────────
local W = REL .. "/ws"
local WA = A .. "/ws"
local TGT = A .. "/ws-target"
fs.mkdir(W .. "/crates/alpha/src")
fs.write(W .. "/Cargo.toml", '[workspace]\nmembers = ["crates/alpha"]\nresolver = "3"\n')
fs.write(W .. "/crates/alpha/Cargo.toml",
    '[package]\nname = "fixture-alpha"\nversion = "0.1.0"\nedition = "2024"\npublish = false\n')
local CLEAN = "pub fn one() -> u8 {\n    1\n}\n"
fs.write(W .. "/crates/alpha/src/lib.rs", CLEAN)
fs.write(W .. "/README.md", "fixture\n")
-- the lock cargo writes on its first run is not a root Cargo change
fs.write(W .. "/.gitignore", "Cargo.lock\n")
local function git(...)
    return proc.run({ argv = { "git", "-C", WA, "-c", "user.name=fixture", "-c", "user.email=fixture@invalid", ... },
        timeout_ms = 30000 })
end
git("init", "-q")
git("add", "-A")
git("commit", "-q", "-m", "base")
local BASE = text.trim(git("rev-parse", "HEAD").stdout or "")

local function guard(mode)
    local r = proc.run({ argv = { PLAN, "script", "run", ROOT .. "/scripts/lua/check-rust-lints.lua", "--", mode, WA },
        cwd = ROOT, env = { CARGO_TARGET_DIR = TGT, TILLANDSIAS_RUST_LINTS_BASE = BASE }, timeout_ms = 900000 })
    return (r.status == "exited" and r.code or -1), text.trim((r.stdout or "") .. "\n" .. (r.stderr or ""))
end

local rc, o = guard("fmt")
arm("1 FMT-OK a formatted crate passes", rc == 0 and o:find("ok:rust-fmt", 1, true) ~= nil, "rc=" .. rc .. " " .. o)

fs.write(W .. "/README.md", "fixture, edited\n")
rc, o = guard("clippy")
arm("3 UNTOUCHED a change outside crates/ runs no cargo",
    rc == 0 and o:find("skip:rust-clippy:no-crate-touched", 1, true) ~= nil and not fs.exists(REL .. "/ws-target"),
    "rc=" .. rc .. " target-exists=" .. tostring(fs.exists(REL .. "/ws-target")) .. " " .. o)

fs.write(W .. "/crates/alpha/src/lib.rs", CLEAN .. "pub fn two( ) -> u8 { 2 }\n")
rc, o = guard("fmt")
arm("2 FMT-HIT one unformatted hunk is refused, naming the file",
    rc == 1 and o:find("refused:rust-fmt:crates/alpha/src/lib.rs", 1, true) ~= nil, "rc=" .. rc .. " " .. o)

fs.write(W .. "/crates/alpha/src/lib.rs", table.concat({
    "pub fn pick(a: bool, b: bool) -> u8 {",
    "    if a {",
    "        if b {",
    "            return 1;",
    "        }",
    "    }",
    "    0",
    "}",
    "" }, "\n"))
rc, o = guard("clippy")
arm("4 CLIPPY-HIT collapsible_if in a touched crate is refused, naming package and lint",
    rc == 1 and o:find("refused:rust-clippy:fixture-alpha:clippy::collapsible_if", 1, true) ~= nil
    and o:find("lint:fixture-alpha:clippy::collapsible_if:crates/alpha/src/lib.rs:2", 1, true) ~= nil,
    "rc=" .. rc .. " " .. o)

fs.write(W .. "/crates/alpha/src/lib.rs", CLEAN .. "\npub fn two() -> u8 {\n    2\n}\n")
rc, o = guard("clippy")
arm("5 CLIPPY-OK the touched crate, clean, passes naming it",
    rc == 0 and o:find("ok:rust-clippy:fixture-alpha", 1, true) ~= nil, "rc=" .. rc .. " " .. o)

-- ── the door ────────────────────────────────────────────────────────────────
local function extract(text_, name)
    local acc, on = {}, false
    for l in (text_ .. "\n"):gmatch("(.-)\n") do
        if l:match("^" .. name .. "%(%) {") then on = true end
        if on then
            acc[#acc + 1] = l
            if l == "}" then break end
        end
    end
    return table.concat(acc, "\n")
end
local build = fs.read("build.sh")
local parts = {}
for _, n in ipairs({ "_preflight_roster", "_preflight_preconditions", "_pf_predecide", "_pf_long_lane",
    "_pf_sweep_under", "_pf_sweep_guard_tmp", "_pf_sweep_fixture_scratch", "_pf_sweep_declared_artifacts",
    "_pf_now", "_pf_budget", "_pf_run_guard", "_pf_guard_deadline", "_pf_launcher" }) do
    local f = extract(build, n)
    if f == "" then
        verdict.emit("violation:rust-lints-fixture:no-subject:" .. n, 1, "build.sh has no " .. n .. " (1631-6w8z)")
    end
    parts[#parts + 1] = f
end
local fns = table.concat(parts, "\n") .. "\n"
fs.write(REL .. "/door-post.sh", fns)
local SRC6 = "printf '%s\\t%s\\n' scripts/lua/check-rust-lints.lua fmt scripts/lua/check-rust-lints.lua clippy"
local pre, nsub = fns:gsub("\n%s*" .. SRC6:gsub("[%%%$%(%)%.%-%[%]%*%+%?%^]", "%%%0") .. "\n", "\n")
fs.write(REL .. "/door-pre.sh", pre)

local function bash(lines, extra_env)
    fs.write(REL .. "/harness.sh", table.concat(lines, "\n") .. "\n")
    local r = proc.run({ argv = { "bash", A .. "/harness.sh" }, cwd = ROOT, env = extra_env, timeout_ms = 120000 })
    return text.trim((r.stdout or "") .. "\n" .. (r.stderr or ""))
end

local function roster(which)
    return bash({ "set -u", "SCRIPT_DIR=" .. ROOT, ". " .. A .. "/door-" .. which .. ".sh", "_preflight_roster" })
end
local rpost, rpre = roster("post"), roster("pre")
local function count(s, pat) local _, c = s:gsub(pat, "") return c end
arm("6 ROSTER the door carries fmt and clippy; the trunk door (no source 6) asks neither",
    nsub == 1
    and rpost:find("scripts/lua/check-rust-lints.lua\tfmt", 1, true) ~= nil
    and rpost:find("scripts/lua/check-rust-lints.lua\tclippy", 1, true) ~= nil
    and rpre:find("check-rust-lints", 1, true) == nil,
    "removed=" .. nsub .. " post-entries=" .. count(rpost, "check%-rust%-lints") .. " pre-entries=" .. count(rpre, "check%-rust%-lints"))

-- a scratch SCRIPT_DIR with three planted guards
local D = REL .. "/door"
fs.mkdir(D .. "/scripts")
fs.write(D .. "/scripts/test-slow.sh", "#!/usr/bin/env bash\n# preflight: own-deadline — sleeps 30 s\nexec sleep 30\n")
fs.write(D .. "/scripts/test-quick.sh", "#!/usr/bin/env bash\n# preflight: own-deadline — fixture\necho ok:quick\n")
fs.write(D .. "/scripts/test-bare.sh", "#!/usr/bin/env bash\n# preflight: own-deadline\necho ok:bare\n")
local DA = A .. "/door"
local function lane(roster_lines, limit, pre_lines)
    local L = { "set -u", "SCRIPT_DIR=" .. DA, ". " .. A .. "/door-post.sh", "W=$(mktemp -d)" }
    for _, l in ipairs(pre_lines or {}) do L[#L + 1] = l end
    L[#L + 1] = "printf '" .. table.concat(roster_lines, "\\n") .. "\\n' | _pf_long_lane \"$W\" " .. limit
    L[#L + 1] = 'for f in "$W"/*.rc "$W"/*.lane-deadline; do [ -f "$f" ] && echo "${f##*/}=$(cat "$f")"; done'
    L[#L + 1] = '[ ! -f "$W/1.out" ] || cp "$W/1.out" ' .. A .. "/lane-1.out"
    L[#L + 1] = 'rm -rf "$W"'
    return L
end
o = bash(lane({ "scripts/test-slow.sh" }, 1), { TILLANDSIAS_PREFLIGHT_LANE_TIMEOUT = "1" })
local slow_rc = o:match("1%.rc=(%d+)")
local cls = ""
if slow_rc then
    local c = proc.run({ argv = { PLAN, "script", "classify", "--rc", slow_rc, "--file", A .. "/lane-1.out" },
        cwd = ROOT, timeout_ms = 30000 })
    cls = text.trim(c.stdout or "")
end
arm("7 DEADLINE a guard outliving the lane deadline ends rc 124 and is booked timed-out, not refused",
    slow_rc == "124" and cls == "timed-out" and o:find("1.lane-deadline=1", 1, true) ~= nil,
    o .. " classify=" .. cls)

o = bash(lane({ "scripts/test-quick.sh" }, 1, { "_pf_wall0=$(( SECONDS - 5 ))" }), { TILLANDSIAS_PREFLIGHT_BUDGET_S = "7" })
local o_full = bash(lane({ "scripts/test-quick.sh" }, 0), { TILLANDSIAS_PREFLIGHT_BUDGET_S = "7" })
arm("8 BUDGET the lane deadline is the budget left (7 s budget, 5 s spent: 2 s); --full lifts it (0)",
    (o:find("1.lane-deadline=2", 1, true) ~= nil or o:find("1.lane-deadline=1", 1, true) ~= nil)
    and o:find("1.rc=0", 1, true) ~= nil
    and o_full:find("1.lane-deadline=0", 1, true) ~= nil and o_full:find("1.rc=0", 1, true) ~= nil,
    "budget [" .. o .. "] full [" .. o_full .. "]")

o = bash(lane({ "scripts/test-bare.sh" }, 1))
local pd = bash({ "set -u", "SCRIPT_DIR=" .. DA, ". " .. A .. "/door-post.sh",
    'rc=0; _pf_predecide scripts/test-bare.sh bare || rc=$?; echo "pd=$rc"' })
arm("9 NO-REASON a bare own-deadline declaration is run under the per-guard deadline, with a note",
    o:find("1.rc", 1, true) == nil and pd:find("pd=0", 1, true) ~= nil
    and pd:find("own-deadline-without-a-reason", 1, true) ~= nil, "lane [" .. o .. "] predecide [" .. pd .. "]")

o = bash({ "set -u", "SCRIPT_DIR=" .. DA, ". " .. A .. "/door-post.sh", "W=$(mktemp -d)",
    "printf 'scripts/test-quick.sh\\nscripts/test-bare.sh\\n' | _pf_launcher \"$W\" 5 2",
    'for f in "$W"/*.rc; do [ -f "$f" ] && echo "${f##*/}=$(cat "$f")"; done', 'rm -rf "$W"' })
arm("10 LAUNCHER the roster launcher leaves an own-deadline guard to the lane, and runs a bare one",
    o:find("1.rc", 1, true) == nil and o:find("2.rc=0", 1, true) ~= nil, o)

proc.run({ argv = { "rm", "-rf", A }, timeout_ms = 60000 })
if #failed > 0 then
    verdict.emit("violation:rust-lints-fixture:" .. #failed .. "-failed", 1)
end
verdict.ok("rust-lints-fixture", "10 arms")
