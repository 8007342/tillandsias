-- @trace order:2215-beb5, order:1242-4x53, order:880-tdwn, spec:methodology-accountability
-- @env CARGO_TARGET_DIR
-- @env RUSTFLAGS
-- @env RUSTDOCFLAGS
-- @env CARGO_HOME
-- @env RUSTUP_HOME
-- @env RUSTUP_TOOLCHAIN
-- @env CARGO_BUILD_JOBS
-- @env CARGO_INCREMENTAL
-- @env RUST_BACKTRACE
-- @env RUST_TEST_THREADS
--
-- run-rust-test-on-host.lua — local-ci.sh to Lua, slice 1 (2215-beb5): the
-- rust-test runner (run_rust_test_on_host) and the same-regime re-run of the
-- FAILED tests (scripts/lib-rerun-failed-rust-tests.sh, 1242-4x53).
--
--   run   [--regime NAME] -- <argv...>
--     Runs argv from the repository root with TILLANDSIAS_PODMAN_REFUSE_REAL=1
--     (880-tdwn: every cargo TEST invocation runs with the real-podman tripwire
--     armed), printing its output. The bash function inherited the caller's
--     whole environment; this runner's children are scrubbed by design, so the
--     environment a test run depends on is carried EXPLICITLY: the PASS_THROUGH
--     names below, each forwarded when set. The list is printed in the verdict
--     and the values written to the regime file, so a reader can see what the
--     run was given and the re-run can prove it was given the same.
--       ok:rust-test-on-host:pass pass-through=<names>             exit 0
--       violation:rust-test-on-host:rc=<n> pass-through=<names>    exit 1
--
--   rerun [--regime NAME] <cargo-test-log> -- <argv...>
--     Re-runs, ONCE, exactly the tests the log reports as FAILED (argv, then
--     `-- --exact <names>`), and says whether the failure REPRODUCED. Before
--     anything runs it compares the CURRENT regime with the one `run` recorded,
--     and refuses by name if any pass-through value differs: a re-run in a
--     different regime is the mistake that made 1242-4x53's first failure look
--     flaky (the standalone re-run lacked TILLANDSIAS_PODMAN_REFUSE_REAL).
--       ok:rust-test-rerun:reproduced=yes|no                        exit 0
--       skip:rust-test-rerun:no-failed-names | :no-log             exit 0
--       refused:rust-test-rerun:regime-differs:<names>              exit 1
--       could-not-run:rust-test-rerun:no-recorded-regime            exit 3
--     The re-run's own output is discarded: its verdict is data beside a
--     failure that is already recorded, not a second gate.
--
-- The regime file is target/plan-scratch/rust-test-regime-<NAME>.env
-- (NAME defaults to rust-tests), one NAME=value or NAME (unset) per line.

local PASS_THROUGH = { "CARGO_TARGET_DIR", "RUSTFLAGS", "RUSTDOCFLAGS", "CARGO_HOME", "RUSTUP_HOME",
    "RUSTUP_TOOLCHAIN", "CARGO_BUILD_JOBS", "CARGO_INCREMENTAL", "RUST_BACKTRACE", "RUST_TEST_THREADS" }
local NAMES = table.concat(PASS_THROUGH, ",")

-- Arguments: <mode> [--regime NAME] [<log>] -- <argv...>
local mode = arg[1]
local regime_name, log_path, argv = "rust-tests", nil, {}
local i, seen_sep = 2, false
while arg[i] do
    local a = arg[i]
    if seen_sep then argv[#argv + 1] = a
    elseif a == "--" then seen_sep = true
    elseif a == "--regime" then i = i + 1; regime_name = arg[i] or regime_name
    elseif not log_path then log_path = a end
    i = i + 1
end
if (mode ~= "run" and mode ~= "rerun") or #argv == 0 or not regime_name:match("^[a-z0-9%-]+$") then
    verdict.refused("rust-test-on-host:usage",
        "usage: run [--regime NAME] -- <argv...> | rerun [--regime NAME] <log> -- <argv...>")
end
local REGIME = "target/plan-scratch/rust-test-regime-" .. regime_name .. ".env"

-- The regime as it is NOW: the environment forwarded to the child, and its record.
local function current()
    local e, lines = { TILLANDSIAS_PODMAN_REFUSE_REAL = "1" }, {}
    for _, n in ipairs(PASS_THROUGH) do
        local v = env.get(n)
        if v then e[n] = v; lines[#lines + 1] = n .. "=" .. v else lines[#lines + 1] = n end
    end
    return e, lines
end

if mode == "run" then
    local e, lines = current()
    proc.run{ argv = { "mkdir", "-p", "target/plan-scratch" } }
    fs.write(REGIME, table.concat(lines, "\n") .. "\n")
    local r = proc.run{ argv = argv, env = e, timeout_ms = 7200000 }
    for _, l in ipairs(text.lines((r.stdout or ""):gsub("\n$", ""))) do out.line(l) end
    for _, l in ipairs(text.lines((r.stderr or ""):gsub("\n$", ""))) do log.raw(l) end
    if r.code == 0 then verdict.emit("ok:rust-test-on-host:pass pass-through=" .. NAMES, 0) end
    verdict.emit("violation:rust-test-on-host:rc=" .. tostring(r.code) .. " pass-through=" .. NAMES, 1)
end

-- rerun ---------------------------------------------------------------------
local logr = proc.run{ argv = { "cat", log_path or "" } }
if not log_path or not logr.ok then verdict.skip("rust-test-rerun:no-log") end
local names, seen = {}, {}
for _, l in ipairs(text.lines(logr.stdout or "")) do
    local n = l:match("^test (.*) %.%.%. FAILED$")
    if n and not seen[n] then seen[n] = true; names[#names + 1] = n end
end
if #names == 0 then verdict.skip("rust-test-rerun:no-failed-names") end
table.sort(names)

if not fs.exists(REGIME) then
    verdict.could_not_run("rust-test-rerun:no-recorded-regime",
        REGIME .. " is absent: nothing says what the first run was given, so a re-run cannot be called same-regime")
end
local recorded = {}
for _, l in ipairs(text.lines(fs.read(REGIME) or "")) do
    if l ~= "" then recorded[#recorded + 1] = l end
end
local e, lines = current()
local differs = {}
for idx, n in ipairs(PASS_THROUGH) do
    if recorded[idx] ~= lines[idx] then differs[#differs + 1] = n end
end
if #differs > 0 then
    local why = {}
    for _, n in ipairs(differs) do
        local was, now = "unset", "unset"
        for _, l in ipairs(recorded) do if l:match("^" .. n .. "=") then was = l:sub(#n + 2) end end
        for _, l in ipairs(lines) do if l:match("^" .. n .. "=") then now = l:sub(#n + 2) end end
        why[#why + 1] = n .. ": first run " .. was .. ", re-run " .. now
    end
    verdict.emit("refused:rust-test-rerun:regime-differs:" .. table.concat(differs, ","), 1,
        table.concat(why, "; ") .. " — a re-run in a different regime cannot say whether the failure reproduces (1242-4x53)")
end

local a = {}
for _, x in ipairs(argv) do a[#a + 1] = x end
a[#a + 1] = "--"; a[#a + 1] = "--exact"
for _, n in ipairs(names) do a[#a + 1] = n end
local rr = proc.run{ argv = a, env = e, timeout_ms = 7200000 }
verdict.ok("rust-test-rerun:reproduced=" .. (rr.code == 0 and "no" or "yes"))
