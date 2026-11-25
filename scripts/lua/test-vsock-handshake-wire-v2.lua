-- @trace spec:vsock-transport, order:1492-fswq, order:2172-7n62
-- @env PATH HOME CARGO_HOME RUSTUP_HOME RUSTUP_TOOLCHAIN CARGO_TARGET_DIR
--
-- test-vsock-handshake-wire-v2.lua — the wire-v2 Hello/HelloAck handshake.
-- Ported from the .sh of the same name (order 2172-7n62); same preconditions,
-- same three cargo runs, same pass/skip/fail outcomes.
--
-- ORDER 1492-fswq. The version is READ from the named constant and checked as a
-- FLOOR (v2 is the framing generation this test exercises; later versions are
-- additive), and each precondition names itself when it fails: the old literal
-- grep for `WIRE_VERSION: u16 = 2` found nothing once the wire moved on, and the
-- litmus exited 1 with NO output.
--
-- Usage: tillandsias-plan script run scripts/lua/test-vsock-handshake-wire-v2.lua
-- Verdicts:
--   ok:vsock-handshake-wire-v2:hello-helloack-completed          exit 0
--   skip:vsock-handshake-wire-v2:<not-linux|no-vsock-loopback>   exit 0
--   violation:vsock-handshake-wire-v2:<why>                      exit 1

local NAME = "vsock-handshake-wire-v2"
local function fail(why) verdict.emit("violation:" .. NAME .. ":" .. why, 1) end
local E = {}
for _, k in ipairs({ "PATH", "HOME", "CARGO_HOME", "RUSTUP_HOME", "RUSTUP_TOOLCHAIN", "CARGO_TARGET_DIR" }) do E[k] = env.get(k) end
local function run(argv) return proc.run({ argv = argv, env = E, timeout_ms = 1800000 }) end

local lib = fs.read("crates/tillandsias-control-wire/src/lib.rs") or ""
local wv = lib:match("\npub const WIRE_VERSION: u16 = (%d+);")
if not wv then fail("could not read WIRE_VERSION from crates/tillandsias-control-wire/src/lib.rs") end
if tonumber(wv) < 2 then fail("WIRE_VERSION is " .. wv .. "; this handshake test needs wire v2 framing or later") end
if not text.contains(fs.read("openspec/specs/vsock-transport/spec.md") or "", "vsock-transport.invariant.wire-version-2") then
    fail("spec invariant vsock-transport.invariant.wire-version-2 is missing")
end
if not fs.read("crates/tillandsias-headless/tests/vsock_listener_e2e.rs") then
    fail("crates/tillandsias-headless/tests/vsock_listener_e2e.rs is missing")
end
out.line("ok: preconditions (WIRE_VERSION=" .. wv .. ", >= 2)")
if text.contains(fs.read("openspec/litmus-tests/litmus-vsock-handshake.yaml") or "", "vsock-handshake-probe") then
    fail("handshake descriptor invokes removed probe example")
end

for _, argv in ipairs({
    { "cargo", "test", "-q", "-p", "tillandsias-control-wire", "hello_" },
    { "cargo", "test", "-q", "-p", "tillandsias-host-shell", "handshake_succeeds_against_fake_unix_server" },
}) do
    local r = run(argv)
    if r.code ~= 0 then
        log.raw((r.stdout or "") .. (r.stderr or ""))
        fail(argv[5] .. " unit tests failed (rc=" .. tostring(r.code) .. ")")
    end
end

local os_name = text.trim(run({ "uname", "-s" }).stdout or "")
if os_name ~= "Linux" then verdict.emit("skip:" .. NAME .. ":not-linux", 0) end

local r = run({ "cargo", "test", "-p", "tillandsias-headless", "--features", "listen-vsock",
    "--test", "vsock_listener_e2e", "--", "--ignored", "--nocapture" })
local all = (r.stdout or "") .. "\n" .. (r.stderr or "")
log.raw(all)
if r.code ~= 0 then fail("maintained wire-v2 vsock handshake fixture failed (rc=" .. tostring(r.code) .. ")") end
if text.contains(all, "[skip] vsock loopback not available") then verdict.emit("skip:" .. NAME .. ":no-vsock-loopback", 0) end
local one = false
for _, l in ipairs(text.lines(all)) do if l:match("^test result: ok%. 1 passed") then one = true end end
if not one then fail("vsock fixture did not execute exactly one handshake test") end
verdict.ok(NAME, "hello-helloack-completed")
