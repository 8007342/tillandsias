-- @trace spec:windows-native-tray, order:620-duta, order:1667-6rtp
-- @env TILLANDSIAS_IMPORT_FIXTURE TILLANDSIAS_TRAY_EXE
--
-- check-tray-import-surface.lua — make the "zero dependencies ephemeral
-- portable tool" promise FALSIFIABLE for the Windows tray by reading the built
-- binary's actual PE import table and refusing any DLL Windows does not ship
-- in-box. (Ported from scripts/check-tray-import-surface.sh, the shell-to-lua
-- item 1667-6rtp carried; same rule, grammar, knobs and exit codes.)
--
-- This is not theoretical. Rust's MSVC targets link the C runtime dynamically
-- by default, which put `vcruntime140.dll` — a Visual C++ Redistributable
-- component, not an OS component — in the tray's imports. A clean Windows
-- machine without the redist would have failed to start the binary, while every
-- developer machine (which has it) reported success. Static CRT removed it; this
-- check is what keeps it removed.
--
-- Emits exactly one line matching the falsifiable grammar:
--   ^(ok:import-surface-os-only|violation:non-os:[a-z0-9.,_+-]+|skip:(no-tray-binary|no-import-reader))$
-- The refusal was a bare `non-os:` in the .sh; the runtime emits only house
-- prefixes, so the port says `violation:non-os:` (exit 1 as before).
-- Exit 0 on ok and on either skip; 1 on a non-OS import.
--
-- The two skips are deliberate and are NOT failures: this runs in a corpus that
-- also executes on Linux and macOS hosts, where there is no tray binary to read,
-- and refusing there would make the check a platform gate instead of a contract
-- check.

-- DLLs shipped with Windows 10+ in-box. Anything outside this set is a runtime
-- dependency the user would have to install, which is exactly what the portable
-- promise forbids.
--
-- `api-ms-win-*` are the API-set stubs, including the UCRT
-- (`api-ms-win-crt-*`), which IS an OS component since Windows 10 — unlike
-- `vcruntime140.dll`, which is not. Keeping that distinction is the whole point
-- of the list; collapsing it would let the redist dependency back in.
local OS_SHIPPED = {}
for _, dll in ipairs({
    "advapi32.dll", "bcrypt.dll", "bcryptprimitives.dll", "combase.dll", "comctl32.dll",
    "crypt32.dll", "dbghelp.dll", "dnsapi.dll", "gdi32.dll", "iphlpapi.dll", "kernel32.dll",
    "ncrypt.dll", "netapi32.dll", "ntdll.dll", "ole32.dll", "oleaut32.dll", "powrprof.dll",
    "psapi.dll", "secur32.dll", "shell32.dll", "shlwapi.dll", "user32.dll", "userenv.dll",
    "version.dll", "winmm.dll", "ws2_32.dll", "wtsapi32.dll",
}) do OS_SHIPPED[dll] = true end

local function is_os_shipped(dll)
    return dll:sub(1, 11) == "api-ms-win-" or OS_SHIPPED[dll] == true
end

-- Lowercased, de-duplicated and sorted, as `tr | sort -u` gave the shell guard.
local function normalise(list)
    local seen, out = {}, {}
    for _, d in ipairs(list) do
        local l = d:lower()
        if l ~= "" and not seen[l] then seen[l] = true; out[#out + 1] = l end
    end
    table.sort(out)
    return out
end

local imports = {}
local fixture = env.get("TILLANDSIAS_IMPORT_FIXTURE")
if fixture ~= nil and fixture ~= "" then
    -- Test seam: a newline- or space-separated DLL list stands in for objdump,
    -- so BOTH directions of this check are exercisable without building a
    -- binary that deliberately depends on a redist.
    for w in fixture:gmatch("%S+") do imports[#imports + 1] = w end
else
    -- 1043-kvvn: the cargo bin target is tillandsias-windows-tray; the shipped
    -- artifact is still tillandsias-tray.exe, so an INSTALLED path passed via
    -- TILLANDSIAS_TRAY_EXE keeps its name and only the dev-build default moves.
    local tray_exe = env.get("TILLANDSIAS_TRAY_EXE") or "target/release/tillandsias-windows-tray.exe"
    -- Asked of `test`, not fs.exists: an installed exe lives outside the
    -- repository, where the runtime's fs reads are refused.
    local present = proc.run({ argv = { "test", "-f", tray_exe } })
    if present.status ~= "exited" or present.code ~= 0 then
        verdict.emit("skip:no-tray-binary", 0)
    end
    local reader = nil
    for _, candidate in ipairs({ "objdump", "llvm-objdump" }) do
        local v = proc.run({ argv = { candidate, "--version" } })
        if v.status == "exited" and v.code == 0 then reader = candidate; break end
    end
    if reader == nil then verdict.emit("skip:no-import-reader", 0) end
    local r = proc.run({ argv = { reader, "-p", tray_exe }, timeout_ms = 60000 })
    for line in (r.stdout or ""):gmatch("[^\n]+") do
        local name = line:match("^%s*[Dd][Ll][Ll] [Nn][Aa][Mm][Ee]:%s*(%S+)")
        if name then imports[#imports + 1] = name end
    end
    if #imports == 0 then
        -- A PE with no readable import table is not a pass. Treat an empty read
        -- as an unusable reader rather than silently reporting a clean surface.
        verdict.emit("skip:no-import-reader", 0)
    end
end

local offenders = {}
for _, dll in ipairs(normalise(imports)) do
    if not is_os_shipped(dll) then offenders[#offenders + 1] = dll end
end

if #offenders > 0 then verdict.emit("violation:non-os:" .. table.concat(offenders, ","), 1) end
verdict.emit("ok:import-surface-os-only", 0)
