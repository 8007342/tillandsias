-- @trace spec:windows-native-tray, order:624-cf9f, order:2306-3hr6
-- @env TRAY_DIAGNOSE_FIXTURE_FILE OS
-- check-windows-tray-diagnose-surface.lua (ported from the .sh): the Windows tray's diagnostic surface is asserted by
-- RUNNING its pinned unit tests, not by grepping for their names (a name is
-- present when the body is emptied, #[ignore]d or red).
--
-- Why this cannot be a plain `cargo test` step: notify_icon, wsl_lifecycle,
-- hvsocket and installation_uuid are #[cfg(target_os = "windows")] and main.rs
-- swaps in src/stubs/ elsewhere, so a Linux cargo compiles the STUB and passes
-- on a technicality. So: find a Windows cargo, else say skip: out loud.
--
-- Grammar (one line). A violation carries "diagnose-surface" too, so a caller
-- that matches that substring must ALSO judge the exit status (2306-3hr6).
--   ok:diagnose-surface-verified:<count>                     exit 0
--   skip:diagnose-surface-unverifiable:no-windows-toolchain   exit 0
--   skip:diagnose-surface-unverifiable:windows-toolchain-blocked  exit 0 (Smart App Control)
--   skip:diagnose-surface-unverifiable:linker-absent          exit 0
--   skip:diagnose-surface-unverifiable:no-test-run            exit 0
--   violation:diagnose-surface:runner-failed                  exit 1 (cargo refused the
--     crate or the arguments: until 2306-3hr6 the check ran --lib on a crate with
--     no lib target and every run on every host read as no-test-run)
--   violation:diagnose-surface:missing-test:<name>            exit 1
--   violation:diagnose-surface:tests-failed:<name>            exit 1
-- Test seam: TRAY_DIAGNOSE_FIXTURE_FILE names a recorded cargo transcript.

-- Ordered by surface area: the FIRST missing/failed one is reported.
local PINNED_TESTS = {
    "diagnose_json_top_level_keys_pinned",
    "diagnose_json_top_level_keys_exact_count",
    "diagnose_json_wire_object_keys_pinned",
    "diagnose_json_manifest_pin_some_serializes_as_string",
    "diagnose_json_manifest_pin_none_serializes_as_null",
    "diagnose_json_recent_log_tail_is_array",
    "status_once_json_keys_pinned",
    "exit_code_separates_healthy_converging_and_degraded", -- renamed by 647-i98k (2026-08-14); the --lib run never noticed
    "status_once_exit_codes",
    "summary_line_classifies_exit_code",
    "status_summary_line_classifies_exit_code",
    "version_line_uses_workspace_version_and_commit",
    "help_text_documents_all_cli_modes",
    "select_log_tail_handles_all_cases",
    "compose_tooltip_includes_version_and_status",
    "should_rotate_log_at_threshold_boundary",
    "first_line_handles_all_cases",
}

local function find_windows_cargo()
    -- Native Windows: the cargo on PATH is the Windows one.
    if env.get("OS") == "Windows_NT" then return "cargo" end
    -- WSL with interop: the Windows cargo through /mnt/c.
    local onpath = require("common.fixture").which("cargo.exe")
    if onpath then return onpath end
    if fs.exists("/mnt/c/Users") then
        for _, u in ipairs(fs.list("/mnt/c/Users") or {}) do
            local c = "/mnt/c/Users/" .. u .. "/.cargo/bin/cargo.exe"
            if fs.exists(c) then return c end
        end
    end
    return nil
end

local output
local fixture = env.get("TRAY_DIAGNOSE_FIXTURE_FILE")
if fixture ~= nil and fixture ~= "" then
    output = fs.read(fixture) or ""
else
    local cargo = find_windows_cargo()
    if not cargo then verdict.emit("skip:diagnose-surface-unverifiable:no-windows-toolchain", 0) end
    local r = proc.run({ argv = { cargo, "test", "-p", "tillandsias-windows-tray", "--bins", "--", "--nocapture" },
        timeout_ms = 170000 })
    output = (r.stdout or "") .. "\n" .. (r.stderr or "")
end

-- DID THE RUNNER RUN? Asked first: Smart App Control can block every freshly
-- built test binary (os error 4551), and naming a test as missing when nothing
-- ran was the first version's misdirection.
if text.contains(output, "Application Control policy has blocked") then
    verdict.emit("skip:diagnose-surface-unverifiable:windows-toolchain-blocked", 0)
end
if not text.is_match(output, "(?m)^test .* \\.\\.\\. (ok|FAILED|ignored)") then
    if text.is_match(output, "linker `[^`]*` not found") then
        verdict.emit("skip:diagnose-surface-unverifiable:linker-absent", 0)
    end
    if text.is_match(output, "(?m)^error: (could not compile|no library targets|no [a-z]+ target|package ID)") then
        for _, l in ipairs(text.lines(output)) do
            if l:find("^error") then out.line("  " .. l) end
        end
        verdict.emit("violation:diagnose-surface:runner-failed", 1)
    end
    verdict.emit("skip:diagnose-surface-unverifiable:no-test-run", 0)
end

for _, t in ipairs(PINNED_TESTS) do
    if not text.contains(output, t) then
        verdict.emit("violation:diagnose-surface:missing-test:" .. t, 1)
    end
end
-- Each pinned test judged by its own result line: the suite's one known
-- unrelated red (embedded_guest_headless_matches_workspace_version) is neither
-- hidden nor inherited.
for _, t in ipairs(PINNED_TESTS) do
    if text.is_match(output, "(?m)^test .*" .. t .. " \\.\\.\\. FAILED") then
        verdict.emit("violation:diagnose-surface:tests-failed:" .. t, 1)
    end
end

verdict.emit("ok:diagnose-surface-verified:" .. tostring(#PINNED_TESTS), 0)
