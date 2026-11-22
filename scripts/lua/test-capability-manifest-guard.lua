-- @trace spec:forge-environment-discoverability
-- @trace order:583-dv9n, order:1114-p2ht, order:2197-h5kv
--
-- test-capability-manifest-guard.lua — PORTED from
-- test-capability-manifest-guard.sh (2197-h5kv), same four ok lines, same
-- FAIL texts, same stop-at-first-failure shape. Builds the compile-time
-- capability-manifest cases in a private source copy under
-- target/plan-scratch: once with `query` dropped from capabilities.txt (the
-- drifted artifact must warn on stderr, not gate, and under-report fail-safe
-- through lib-expert-capability.sh), once clean (silent, full token stream).
-- This fixture executes its own freshly-built artifacts, never a host
-- target/ artifact.
--
-- Verdict: ok:capability-manifest-guard:4 arms | violation:capability-manifest-guard:<step>

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local rel = "target/plan-scratch/litmus-583-" .. tostring(time.now_ms())
local WORK = root .. "/" .. rel
local REPO = WORK .. "/repo"
local MREL = rel .. "/repo/crates/tillandsias-plan/capabilities.txt"
local REAL_MANIFEST = "crates/tillandsias-plan/capabilities.txt"

local function cleanup() proc.run{ argv = { "find", WORK, "-delete" }, timeout_ms = 300000 } end
local function fail(msg, slug)
    out.line("FAIL: " .. msg)
    cleanup()
    verdict.emit("violation:capability-manifest-guard:" .. slug, 1)
end

local function is_token(l) return l:match("^[a-z][a-z0-9%-]*$") ~= nil end
local function count_tokens(s)
    local n = 0
    for _, l in ipairs(text.lines(s)) do if is_token(l) then n = n + 1 end end
    return n
end
local function nlines(s)
    local n = 0
    for _ in s:gmatch("\n") do n = n + 1 end
    if #s > 0 and s:sub(-1) ~= "\n" then n = n + 1 end
    return n
end

proc.run{ argv = { "mkdir", "-p", REPO } }
local cp = { "cp", "-a", "Cargo.toml", "Cargo.lock", "crates", "assets", "images" }
if fs.exists(".cargo") then cp[#cp + 1] = ".cargo" end
cp[#cp + 1] = REPO .. "/"
if not proc.run{ argv = cp, timeout_ms = 300000 }.ok then fail("could not copy the source tree", "copy") end

local function build()
    return proc.run{ argv = { "cargo", "build", "-q", "--manifest-path", REPO .. "/Cargo.toml",
        "-p", "tillandsias-plan", "--release" }, env = { CARGO_TARGET_DIR = WORK .. "/target" },
        timeout_ms = 1800000 }
end
local BIN = WORK .. "/target/release/tillandsias-plan"

-- Drift: drop `query` from the copy's manifest.
local real = fs.read(REAL_MANIFEST) or ""
local trimmed = {}
for _, l in ipairs(text.lines(real)) do if l ~= "query" then trimmed[#trimmed + 1] = l .. "\n" end end
fs.write(MREL, table.concat(trimmed))
local b = build()
if not (b.ok and proc.run{ argv = { "test", "-x", BIN } }.ok) then
    fail("no drifted tillandsias-plan artifact", "drifted-build")
end
-- Copy it aside: the clean rebuild below replaces the file at BIN.
local DRIFTED = WORK .. "/drifted-tillandsias-plan"
proc.run{ argv = { "cp", BIN, DRIFTED } }
out.line("ok: fixture-drifted-built")

local d = proc.run{ argv = { DRIFTED, "capabilities" }, timeout_ms = 60000 }
local dout, derr = d.stdout or "", d.stderr or ""
local want = count_tokens(real) - 1
if d.code ~= 0 then fail("drifted capabilities exited " .. tostring(d.code), "drifted-rc") end
if not derr:find("warning: dispatch arm 'query' is not listed in capabilities.txt", 1, true) then
    fail("drift warning absent", "drift-warning")
end
if not derr:find("order 583-dv9n", 1, true) then fail("drift warning lacks order", "drift-order") end
for _, l in ipairs(text.lines(dout)) do
    if l == "query" then fail("drifted stdout still lists query", "drift-lists-query") end
    if not is_token(l) then fail("drifted stdout is not a token stream", "drift-stream") end
end
if nlines(dout) ~= want then fail("drifted token count differs", "drift-count") end
out.line("ok: drift-warns-on-stderr-no-gate")

proc.run{ argv = { "mkdir", "-p", WORK .. "/checkout/crates/tillandsias-plan" } }
proc.run{ argv = { "cp", REAL_MANIFEST, WORK .. "/checkout/crates/tillandsias-plan/capabilities.txt" } }
local u = proc.run{ argv = { "sh", "images/default/lib-expert-capability.sh", DRIFTED, WORK .. "/checkout" },
    env = { FORGE_EXPERTS_STATE_DIR = WORK .. "/state" }, timeout_ms = 60000 }
local line = text.lines(u.stdout or "")[1] or ""
if not (line:find("now=answer,append-event", 1, true)
    and line:find("blocked_capabilities=query", line:find("now=answer,append-event", 1, true), true)) then
    fail("under-report did not remain fail-safe: " .. line, "under-report")
end
out.line("ok: under-report-failsafe")

fs.write(MREL, real)
b = build()
local c = proc.run{ argv = { BIN, "capabilities" }, timeout_ms = 60000 }
local cout, cerr = c.stdout or "", c.stderr or ""
if #cerr > 0 then fail("clean artifact wrote stderr: " .. cerr:sub(1, 160), "clean-stderr") end
if nlines(cout) ~= count_tokens(real) then fail("clean token count differs", "clean-count") end
local has_query = false
for _, l in ipairs(text.lines(cout)) do if l == "query" then has_query = true end end
if not has_query then fail("clean artifact lacks query", "clean-query") end
out.line("ok: clean-tree-silent")
out.line("PASS: capability manifest guard (4/4)")
cleanup()
verdict.emit("ok:capability-manifest-guard:4 arms", 0)
