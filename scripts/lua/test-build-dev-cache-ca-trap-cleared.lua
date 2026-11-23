-- @trace order:2228-vt2z, spec:dev-build
--
-- test-build-dev-cache-ca-trap-cleared.lua — pins that build.sh's
-- ensure_dev_cache leaves no RETURN trap behind when CA generation fails
-- (2228-vt2z, the RETURN-trap sweep).
--
-- WHY. ensure_dev_cache sets `trap 'rmdir "$ca_lock" …' RETURN` around CA
-- generation and clears it with `trap - RETURN` on the way out. Its
-- openssl-failure branch returned EARLY, before the clear, so the trap
-- outlived the function. A RETURN trap also fires when a sourced file
-- finishes, so the next top-level `.` in build.sh would run it again with
-- the local ca_lock gone, and under build.sh's `set -u` that is
-- `ca_lock: unbound variable` and an aborted build (measured, bash 5.3).
-- build.sh has no such top-level source after the call today, so it was
-- latent; the same class aborted build.sh once already (2026-08-16, see the
-- RETURN-trap note in scripts/with-tillandsias-builder.sh).
--
-- The arms run the REAL function, extracted from build.sh, on its failure
-- path only: a scratch CACHE_DIR with no CA, and an openssl stub that fails.
-- That path returns before any podman or network work.
--
--   1 after a failed CA generation, a later top-level source still runs (rc 0)
--   2 the CA lock directory is removed on that path
--   3 CONTROL: the stub really failed CA generation (no CA files were written)
--
-- Verdict: ok:build-dev-cache-ca-trap-cleared:3 arms
--        | violation:build-dev-cache-ca-trap-cleared:<n> failed

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local failn = 0
local function ok(m) out.line("ok:   " .. m) end
local function bad(m) out.line("FAIL: " .. m); failn = failn + 1 end

local rel = "target/plan-scratch/build-dev-cache-ca-trap-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", W .. "/bin", W .. "/cache" } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end

fs.write(rel .. "/bin/openssl", "#!/bin/sh\nexit 1\n")
proc.run{ argv = { "chmod", "+x", W .. "/bin/openssl" } }
fs.write(rel .. "/later.sh", ": a file build.sh sources after the call\n")
fs.write(rel .. "/drive.sh", table.concat({
    "set -euo pipefail",
    "W=\"$1\"; ROOT=\"$2\"",
    "_warn() { :; }; _info() { :; }",
    "eval \"$(sed -n '/^ensure_dev_cache() {/,/^}/p' \"$ROOT/build.sh\")\"",
    "CACHE_DIR=\"$W/cache\"",
    "PATH=\"$W/bin:$PATH\"",
    "ensure_dev_cache",
    "echo after-call",
    ". \"$W/later.sh\"",
    "echo after-later-source",
}, "\n") .. "\n")

local r = proc.run{ argv = { "bash", W .. "/drive.sh", W, root }, timeout_ms = 60000 }
local said = (r.stdout or "") .. (r.stderr or "")

if r.code == 0 and said:find("after-later-source", 1, true) then
    ok("1 after a failed CA generation, a later top-level source still runs")
else
    bad("1 rc=" .. tostring(r.code) .. " — a RETURN trap outlived ensure_dev_cache: " .. text.trim(said))
end

if not fs.exists(rel .. "/cache/ca-generation.lock") then ok("2 the CA lock directory is removed on the failure path")
else bad("2 the CA lock directory was left behind") end

if said:find("after-call", 1, true) and not fs.exists(rel .. "/cache/ca-cert.pem")
    and not fs.exists(rel .. "/cache/ca-key.pem") then
    ok("3 CONTROL: the openssl stub failed CA generation and the function returned")
else bad("3 the failure path was not exercised: " .. text.trim(said)) end

cleanup()
if failn == 0 then verdict.ok("build-dev-cache-ca-trap-cleared:3 arms") end
verdict.emit("violation:build-dev-cache-ca-trap-cleared:" .. failn .. " failed", 1)
