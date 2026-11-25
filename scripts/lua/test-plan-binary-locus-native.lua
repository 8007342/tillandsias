-- @env PATH HOME
-- @trace order:1030-i2p8, order:2277-7trt
--
-- test-plan-binary-locus-native.lua — the probe must resolve the artefact NATIVE
-- to the locus it runs in, when both artefacts are present. Ported from the .sh
-- of the same name (order 2277-7trt); same three arms.
--
-- THE DEFECT. On a shared Windows/WSL checkout both target/release/
-- tillandsias-plan (ELF) and tillandsias-plan.exe exist. resolve_plan_binary
-- tried the .exe FIRST, and inside the tillandsias-build WSL2 distro with
-- interop enabled the .exe RUNS, so the probe returned the .exe while
-- ensure_fresh_plan_binary rebuilt the ELF. The .exe stayed stale forever and
-- every floor gate refused (esmeraldinha 2026-09-04: gate6 exit=1 at 7m58s).
--
-- WHY A FIXTURE AND NOT A HOST CHECK. Interop is disabled in that distro today,
-- so a host check would pass for the wrong reason until someone enables it.
-- Both artefacts are SYNTHESISED and runnable here, on any host. The probe asks
-- TILLANDSIAS_PLAN_BIN and CARGO_TARGET_DIR first, and the gate exports them (1258-tpkz;
-- #1446 evicted on it), so both are planted at a runnable decoy and unset before the probe.
--
--   1 NATIVE   both runnable: the probe resolves the extensionless artefact
--   2 CONTROL  the OLD candidate order picks the .exe on the SAME tree; without
--              it arm 1 only says a list is in some order
--   3 OTHER    the ELF cannot execute (the Windows side): falls through to the .exe
--
-- Usage: tillandsias-plan script run scripts/lua/test-plan-binary-locus-native.lua
-- Verdict: ok:plan-binary-locus-native:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("plan-binary-locus-native")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local S = T:scratch()
local REL = "/target/release/tillandsias-plan"
local ENV = { PATH = env.get("PATH"), HOME = env.get("HOME"),
    TILLANDSIAS_PLAN_BIN = S.abs .. "/decoy/release/tillandsias-plan", CARGO_TARGET_DIR = S.abs .. "/decoy" }

fs.mkdir(S.rel .. "/target/release")
fs.mkdir(S.rel .. "/crates/tillandsias-plan/src")
local RUNS = '#!/bin/sh\n[ "$1" = capabilities ] && { echo append-event; exit 0; }\nexit 1\n'
fs.write(S.rel .. REL, RUNS)
fs.write(S.rel .. REL .. ".exe", RUNS)
fs.mkdir(S.rel .. "/decoy/release")
fs.write(S.rel .. "/decoy/release/tillandsias-plan", RUNS)
T:must{ "chmod", "+x", S.abs .. REL, S.abs .. REL .. ".exe", S.abs .. "/decoy/release/tillandsias-plan" }
-- Sources NEWER than the .exe, what a `git pull` produces (GNU touch, else BSD).
local SRC = S.abs .. "/crates/tillandsias-plan/src/main.rs"
fs.write(S.rel .. "/crates/tillandsias-plan/src/main.rs", "fn main() {}\n")
if T:run{ "touch", "-d", "+1 hour", SRC }.code ~= 0 then T:run{ "touch", "-A", "0100", SRC } end

local function sh(script)
    local r = proc.run{ argv = { SH, "-s", "--", ROOT, S.abs }, env = ENV, stdin = script, timeout_ms = 60000 }
    return text.trim(r.stdout or "")
end
local PROBE = 'unset TILLANDSIAS_PLAN_BIN CARGO_TARGET_DIR; . "$1/scripts/plan-binary-probe.sh"; cd "$2" || exit 1; resolve_plan_binary 2>/dev/null\n'
local OLD = [[cd "$2" || exit 1
for c in ./target/release/tillandsias-plan.exe ./target/debug/tillandsias-plan.exe \
         ./target/release/tillandsias-plan ./target/debug/tillandsias-plan; do
    [ -f "$c" ] || continue
    "$c" capabilities >/dev/null 2>&1 || continue
    printf '%s\n' "$c"; exit 0
done
]]
local function ends(s, x) return s:sub(-#x) == x end

local got = sh(PROBE)
T:arm("1 NATIVE with both artefacts runnable, the probe resolves the locus-native one",
    ends(got, REL) and text.contains(got, S.abs:match("[^/]+$")), "got=[" .. got .. "]")
local old = sh(OLD)
T:arm("2 CONTROL the pre-fix order picks the .exe on this same tree", ends(old, "tillandsias-plan.exe"), "got=[" .. old .. "]")
fs.write(S.rel .. REL, "\127ELF not-runnable-here\n")
T:must{ "chmod", "+x", S.abs .. REL }
local other = sh(PROBE)
T:arm("3 OTHER when the native artefact cannot execute, the probe falls through to the .exe",
    ends(other, REL .. ".exe"), "got=[" .. other .. "]")
T:finish()
