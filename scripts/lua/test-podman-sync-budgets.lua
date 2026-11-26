-- @trace order:714-4r6w, order:795-hzpg, order:2400-prg4, spec:podman-orchestration
--
-- test-podman-sync-budgets.lua — fixture for scripts/lua/check-podman-sync-budgets.lua
-- (order 714-4r6w). Ported from test-podman-sync-budgets.sh (2400-prg4); same eleven
-- cases, in its order.
--
-- A gate that only ever passes is decoration. The negative controls are the load-bearing
-- cases: the checker must FAIL on direct std commands, escape-hatch growth, unbounded
-- capture, and sleeping production waits. Every tree is synthetic Rust under kit scratch;
-- nothing runs podman.
--
-- GRAMMAR ok:podman-sync-budgets:<n> arms | violation:podman-sync-budgets:<n>-failed
--       | skip:podman-sync-budgets:no-validator

local fixture = require "common.fixture"
local OUT = out  -- the output module; `out` is reused below for a run's stdout
local T = fixture.new("podman-sync-budgets")
local ROOT = fixture.repo_root()
local LUA_REL = "scripts/lua/check-podman-sync-budgets.lua"
if not fs.exists(LUA_REL) then T:refuse("gate-not-found", LUA_REL) end
local LUA = ROOT .. "/" .. LUA_REL
local PLAN = fixture.plan_binary()
if PLAN == "" then T:skip("no-validator") end
-- is_abs: a native Windows drive path C:/x is absolute too (yolanda msys, #1627).
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end

local W = T:scratch()
local UNSET = { "TILLANDSIAS_*", "PODMAN_SYNC_*", "PROJECT_ROOT" }

local function gate(env)
    local r = T:run{ PLAN, "script", "run", LUA, cwd = ROOT, env = env or {}, env_unset = UNSET,
        timeout_ms = 120000 }
    return r.code, text.trim(r.stdout or ""), (r.stdout or "") .. (r.stderr or "")
end
local function put(rel, body) fs.write(W.rel .. "/" .. rel, body) end
local function mk(rel) fs.mkdir(W.rel .. "/" .. rel) end
local function rm(rel) T:must{ "rm", "-f", W.abs .. "/" .. rel } end
local function has_prefix(s, p) return s:sub(1, #p) == p end
local function hermetic(extra)
    local e = { TILLANDSIAS_REPO_ROOT = W.abs, PODMAN_SYNC_SEARCH_ROOT = "crates" }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
end

-- case 1: the live tree is bounded
local rc, out = gate()
T:arm("case 1: the live tree passes", rc == 0 and has_prefix(out, "ok:podman-sync-bounded:"),
    "rc=" .. tostring(rc) .. " out='" .. out .. "'")

-- case 2 (NEGATIVE CONTROL): a direct std podman Command is refused
mk("crates/fixture/src")
put("crates/fixture/src/bad.rs", [[
fn probe() {
    let mut cmd = std::process::Command::new("podman");
    let _ = cmd.arg("ps").output();
}
]])
rc, out = gate(hermetic())
T:arm("case 2: a direct std podman Command is refused", rc ~= 0 and has_prefix(out, "violation:direct-command:"),
    "rc=" .. tostring(rc) .. " out='" .. out .. "'")

-- case 3 (NEGATIVE CONTROL): the escape hatch cannot grow silently
rm("crates/fixture/src/bad.rs")
put("crates/fixture/src/hatch.rs", [[
fn a() { let _ = cmd.spawn_caller_owned_lifetime(); }
fn b() { let _ = cmd.spawn_caller_owned_lifetime(); }
]])
rc, out = gate(hermetic{ PODMAN_SYNC_ESCAPE_HATCHES = "1" })
T:arm("case 3: a second caller-owned spawn is refused (counted, not merely allowed)",
    rc ~= 0 and out == "violation:escape-hatch-grew:2", "rc=" .. tostring(rc) .. " out='" .. out .. "'")

-- case 4: the reviewed count is what makes case 3 a decision
rc, out = gate(hermetic{ PODMAN_SYNC_ESCAPE_HATCHES = "2" })
T:arm("case 4: raising the reviewed count is the sanctioned path", rc == 0 and out == "ok:podman-sync-bounded:2",
    "rc=" .. tostring(rc) .. " out='" .. out .. "'")

-- case 5 (NEGATIVE CONTROL): an unbounded child-pipe capture is refused (795-hzpg slice A;
-- the scan is scoped to the crate the capped reader lives in)
rm("crates/fixture/src/hatch.rs")
mk("crates/tillandsias-podman/src")
put("crates/tillandsias-podman/src/bad_capture.rs", [[
fn probe(mut pipe: std::process::ChildStdout) {
    let mut buf = Vec::new();
    let _ = pipe.read_to_end(&mut buf);
}
]])
rc, out = gate(hermetic())
T:arm("case 5: an unbounded child-pipe capture is refused", rc ~= 0 and out == "violation:unbounded-capture:1",
    "rc=" .. tostring(rc) .. " out='" .. out .. "'")
rm("crates/tillandsias-podman/src/bad_capture.rs")

-- case 6 (NEGATIVE CONTROL): a sleeping child-wait poll is refused; a test-only poll is not
put("crates/tillandsias-podman/src/busy_wait.rs", [[
/// Documentation may name `thread::sleep` without becoming executable.
fn wait(mut child: std::process::Child) -> std::io::Result<()> {
    loop {
        if child.try_wait()?.is_some() {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}
]])
mk("crates/tillandsias-podman/tests")
put("crates/tillandsias-podman/tests/allowed_poll.rs", [[
fn test_only_wait(mut child: std::process::Child) {
    while child.try_wait().unwrap().is_none() {
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}
]])
rc, out = gate(hermetic())
T:arm("case 6: a sleeping child-wait poll is refused", rc ~= 0 and out == "violation:sleep-poll:1",
    "rc=" .. tostring(rc) .. " out='" .. out .. "'")
rm("crates/tillandsias-podman/src/busy_wait.rs")
rm("crates/tillandsias-podman/tests/allowed_poll.rs")

-- case 7: legacy absolute roots (including spaces) remain readable
local EXT_REL, EXT = "external root", W.abs .. "/external root"
mk(EXT_REL .. "/crates/fixture/src")
put(EXT_REL .. "/crates/fixture/src/bad.rs", 'fn probe() { let _ = std::process::Command::new("podman"); }\n')
rc, out = gate{ PODMAN_SYNC_SEARCH_ROOT = EXT .. "/crates" }
T:arm("case 7: an external root with spaces is scanned through typed listing",
    rc ~= 0 and out == "violation:direct-command:1", "rc=" .. tostring(rc) .. " out='" .. out .. "'")

-- case 8: malformed budgets fail loudly instead of defaulting to one
rc, out = gate(hermetic{ PODMAN_SYNC_ESCAPE_HATCHES = "wat" })
T:arm("case 8: a malformed escape budget blocks explicitly",
    rc == 2 and out == "blocked:podman-sync-bounded:invalid-escape-hatches:wat",
    "rc=" .. tostring(rc) .. " out='" .. out .. "'")

-- case 9: CRLF hatch diagnostics retain the matched source bytes
mk("crlf/crates/fixture/src")
put("crlf/crates/fixture/src/hatch.rs",
    "fn a() { let _ = cmd.spawn_caller_owned_lifetime(); }\r\nfn b() { let _ = cmd.spawn_caller_owned_lifetime(); }\r\n")
local raw
rc, out, raw = gate{ TILLANDSIAS_REPO_ROOT = W.abs .. "/crlf", PODMAN_SYNC_SEARCH_ROOT = "crates",
    PODMAN_SYNC_ESCAPE_HATCHES = "1" }
T:arm("case 9: CRLF hatch growth is refused and its diagnostic keeps the CR byte",
    rc ~= 0 and raw:find("\r", 1, true) ~= nil, "rc=" .. tostring(rc) .. " out='" .. out .. "'")

-- case 10: follow an absolute starting symlink, but not interior links
T:must{ "ln", "-s", EXT .. "/crates", EXT .. "/scan alias" }
rc, out = gate{ PODMAN_SYNC_SEARCH_ROOT = EXT .. "/scan alias" }
T:arm("case 10: an absolute starting symlink is followed", rc ~= 0 and out == "violation:direct-command:1",
    "rc=" .. tostring(rc) .. " out='" .. out .. "'")

-- case 11: a broken external start cannot become a green empty scan.
-- msys ln cannot make a DANGLING symlink without the symlink privilege (yolanda, #1627),
-- so on native Windows the case cannot be set up; it is a named skip there, not a red.
-- posix_shell() with no default answers "bash" everywhere but native Windows.
if fixture.posix_shell() ~= "bash" then
    OUT.line("skip:case-11:native-windows-ln-cannot-make-a-dangling-symlink")
else
T:must{ "ln", "-s", EXT .. "/missing", EXT .. "/broken scan" }
rc, out = gate{ PODMAN_SYNC_SEARCH_ROOT = EXT .. "/broken scan" }
T:arm("case 11: a broken external root blocks, never reports green",
    rc == 2 and has_prefix(out, "blocked:podman-sync-bounded:search-root-unreadable:"),
    "rc=" .. tostring(rc) .. " out='" .. out .. "'")
end

T:finish()
