-- @trace order:2235-zkmx
-- @env LANG
--
-- test-preflight-declarations-host-sed.lua — build.sh's preflight door reads
-- each guard's `# preflight:` declaration header (gate-only,
-- gate-only-decider, serial) with the HOST sed. The decision is
-- _pf_predecide, extracted from build.sh and run on four planted guards in a
-- scratch tree; any sed complaint while reading the headers is a failure.
-- Ported from test-preflight-declarations-host-sed.sh (2235-zkmx); the
-- extract-and-eval stays in one helper file, exactly as the .sh drove it.
--
--   1 gate-only is read with its reason (declared skip, rc 10)
--   2 gate-only-decider is read with its reason (declared skip, rc 10)
--   3 serial is read (run alone, rc 12)
--   4 NEGATIVE CONTROL: an undeclared guard is run (rc 0, nothing printed)
--   5 the host sed accepted every program the door reads headers with
--   6 under LC_ALL=C the em dash is stripped whole, not its first byte
--     (2236-rdj7: a bracket expression [—-] is three bytes in C)
--
-- Verdict: ok:preflight-declarations-host-sed:6 | violation:preflight-declarations-host-sed:<n> failed

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local pass, failn = 0, 0
local function ok(m) pass = pass + 1; out.line("  [OK]   " .. m) end
local function bad(m) failn = failn + 1; out.line("  [FAIL] " .. m) end

if not fs.read("build.sh"):find("\n_pf_predecide() {", 1, true) then
    verdict.emit("violation:preflight-declarations-host-sed:_pf_predecide() not found in build.sh — the door's parser moved; re-point this fixture", 1)
end

local rel = "target/plan-scratch/pf-decl-sed-" .. tostring(time.now_ms())
local S = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", S .. "/scripts/hooks" } }
local function cleanup() proc.run{ argv = { "find", S, "-delete" }, timeout_ms = 60000 } end
local function plant(path, header)
    fs.write(rel .. "/" .. path, "#!/usr/bin/env bash\n" .. (header ~= "" and (header .. "\n") or "") .. "echo ok\n")
end
plant("scripts/test-zz-go.sh", "# preflight: gate-only — drives the litmus runner end to end")
plant("scripts/check-zz-god.sh", "# preflight: gate-only-decider — live synthesis costs seconds per case")
plant("scripts/test-zz-serial.sh", "# preflight: serial — writes target/release/tillandsias-plan")
plant("scripts/test-zz-none.sh", "")

-- decide.sh <build.sh> <scratch> <guard path>: prints the door's stdout, exits
-- with its rc; sed complaints are appended to <scratch>/err.
fs.write(rel .. "/decide.sh", table.concat({
    "fn=\"$(awk '/^_pf_predecide\\(\\) \\{/,/^\\}/' \"$1\")\"",
    "SCRIPT_DIR=\"$2\"",
    "_preflight_preconditions() { :; }",
    "eval \"$fn\"",
    "p=\"$3\"",
    "_pf_predecide \"$p\" \"${p##*/}\" 2>>\"$2/err\"",
}, "\n") .. "\n")
-- Arms 1-5 run the door in the CALLER's locale, as the .sh ran it; arm 6
-- runs it under C, where a `[—-]` bracket once stripped only the em dash's
-- first byte (2236-rdj7).
local LOCALE = { LC_ALL = "", LANG = env.get("LANG") or "C.UTF-8" }
local function decide(path, locale)
    local r = proc.run{ argv = { "bash", S .. "/decide.sh", root .. "/build.sh", S, path }, cwd = root,
        env = locale or LOCALE, timeout_ms = 30000 }
    -- byte-level trim: under C a garbled reason is not valid UTF-8
    local o = (r.stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return tostring(r.code) .. "|" .. o
end

local got = decide("scripts/test-zz-go.sh")
if got == "10|skip:preflight:test-zz-go.sh:gate-only — drives the litmus runner end to end" then
    ok("gate-only is read with its reason (declared skip, rc 10)")
else bad("gate-only was not read: got rc/out '" .. got .. "', want 10 and the named skip") end

got = decide("scripts/check-zz-god.sh")
if got == "10|skip:preflight:check-zz-god.sh:gate-only — live synthesis costs seconds per case" then
    ok("gate-only-decider is read with its reason (declared skip, rc 10)")
else bad("gate-only-decider was not read: got rc/out '" .. got .. "', want 10 and the named skip") end

got = decide("scripts/test-zz-serial.sh")
if got:sub(1, 3) == "12|" then ok("serial is read with its reason (run alone, rc 12)")
else bad("serial was not read: got rc/out '" .. got .. "', want rc 12") end

got = decide("scripts/test-zz-none.sh")
if got == "0|" then ok("NEGATIVE CONTROL: an undeclared guard is run (rc 0, nothing printed)")
else bad("an undeclared guard was not run plainly: got '" .. got .. "'") end

local err = fs.exists(rel .. "/err") and fs.read(rel .. "/err") or ""
if err ~= "" then bad("the host sed complained while the door read headers: " .. (text.lines(err)[1] or ""))
else ok("the host sed accepted every program the door reads headers with") end

got = decide("scripts/test-zz-go.sh", { LC_ALL = "C", LANG = "C" })
if got == "10|skip:preflight:test-zz-go.sh:gate-only — drives the litmus runner end to end" then
    ok("under LC_ALL=C the em dash is stripped whole")
else bad("under LC_ALL=C the reason was garbled: got '" .. got:gsub("[\128-\255]", function(c) return string.format("\\x%02x", c:byte()) end) .. "'") end

local flavour = proc.run{ argv = { "sed", "--version" } }.code == 0 and "gnu-sed" or "bsd-sed"
cleanup()
out.line("preflight-declarations-host-sed: " .. pass .. " passed, " .. failn .. " failed (" .. flavour .. ")")
if failn == 0 then verdict.ok("preflight-declarations-host-sed:" .. pass) end
verdict.emit("violation:preflight-declarations-host-sed:" .. failn .. " failed", 1)
